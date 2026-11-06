//
//  DuckingEngine.swift
//  ClipStudio — Engines/Audio (Audio Studio, Part 3)
//
//  Automatic ducking: finds where speech plays on the chosen "voice" tracks
//  (from cached waveform peaks, mapped through each clip's speed) and writes
//  volume keyframes into the "music" clips so they dip under the voice with smooth
//  attack / release ramps. The result is ordinary volume automation: visible on the
//  timeline, editable, and undoable.
//

import Foundation

struct DuckingSettings: Hashable {
    /// How far the music dips (dB).
    var reductionDB: Double = 12
    /// Level above which a voice track counts as speaking (dBFS).
    var thresholdDB: Double = -36
    /// Ramp down before speech (seconds).
    var attack: Double = 0.25
    /// Ramp back up after speech (seconds).
    var release: Double = 0.6
    /// Pauses shorter than this keep the music down (seconds).
    var hold: Double = 0.5
    var triggerTrackIDs: Set<UUID> = []
    var targetTrackIDs: Set<UUID> = []

    var duckFactor: Double { pow(10, -reductionDB / 20) }
}

enum DuckingEngine {
    private static let step = 0.04

    /// Speech regions (timeline seconds) of one clip, from its source waveform.
    static func speechRegions(of clip: Clip, waveform: Waveform, thresholdDB: Double) -> [TimeSpan] {
        guard clip.isEnabled, !clip.audio.isMuted else { return [] }
        let duration = clip.duration.seconds
        guard duration > 0 else { return [] }
        let threshold = Float(pow(10, thresholdDB / 20))
        var regions: [TimeSpan] = []
        var openStart: Double? = nil
        var local = 0.0
        while local < duration {
            var active = false
            if let source = SpeedMapping.sourceTime(of: clip, local: local) {
                let gain = Float(clip.audio.volume.value(at: local))
                active = waveform.peak(from: source - step / 2, to: source + step / 2) * gain >= threshold
            }
            let time = clip.start.seconds + local
            if active, openStart == nil { openStart = time }
            if !active, let start = openStart {
                regions.append(TimeSpan(start: start, end: time))
                openStart = nil
            }
            local += step
        }
        if let start = openStart { regions.append(TimeSpan(start: start, end: clip.end.seconds)) }
        return regions
    }

    /// Merges regions closer than `hold` and drops very short blips.
    static func consolidate(_ regions: [TimeSpan], hold: Double) -> [TimeSpan] {
        var merged: [TimeSpan] = []
        for region in regions.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, region.start - last.end <= hold {
                merged[merged.count - 1].end = max(last.end, region.end)
            } else {
                merged.append(region)
            }
        }
        return merged.filter { $0.duration >= 0.15 }
    }

    /// Writes ducking volume keyframes into `clip` (replacing its volume automation).
    /// Returns false when no speech overlaps the clip.
    @discardableResult
    static func apply(to clip: inout Clip, speech: [TimeSpan], settings: DuckingSettings) -> Bool {
        let start = clip.start.seconds
        let duration = clip.duration.seconds
        let base = clip.audio.volume.keyframes.isEmpty ? clip.audio.volume.base : clip.audio.volume.value(at: 0)
        let ducked = base * settings.duckFactor
        // Clip-local regions including ramps, merged when ramps would overlap.
        var local: [TimeSpan] = []
        for region in speech {
            let a = region.start - start, b = region.end - start
            guard b > 0, a < duration else { continue }
            let span = TimeSpan(start: max(0, a), end: min(duration, b))
            if let last = local.last, span.start - settings.attack <= last.end + settings.release {
                local[local.count - 1].end = max(last.end, span.end)
            } else {
                local.append(span)
            }
        }
        guard !local.isEmpty else { return false }
        var keys: [Keyframe<Double>] = []
        for span in local {
            let downStart = span.start - settings.attack
            if downStart > 0 {
                keys.append(Keyframe(time: downStart, value: base, easing: .easeInOut))
                keys.append(Keyframe(time: span.start, value: ducked, easing: .linear))
            } else {
                keys.append(Keyframe(time: 0, value: ducked, easing: .linear))
            }
            keys.append(Keyframe(time: span.end, value: ducked, easing: .easeInOut))
            let upEnd = span.end + settings.release
            if upEnd < duration { keys.append(Keyframe(time: upEnd, value: base, easing: .linear)) }
        }
        var cleaned: [Keyframe<Double>] = []
        for key in keys.sorted(by: { $0.time < $1.time }) {
            if let last = cleaned.last, abs(last.time - key.time) < 0.001 {
                cleaned[cleaned.count - 1] = key
            } else {
                cleaned.append(key)
            }
        }
        clip.audio.volume = KeyframedValue(base, keyframes: cleaned)
        return true
    }
}
