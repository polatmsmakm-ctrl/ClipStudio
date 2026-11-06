//
//  AIPlanExecutor.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  Applies the timeline part of an editing-assistant plan with the same pure
//  TimelineEngine operations a person would use (split, trim, delete, move,
//  speed, titles, transitions, volume, color, styles). Each step runs on its own
//  and a failing step is reported, never half-applied. Markers are returned for
//  the project; analysis-based steps (silences, loudness, stabilization, beat
//  sync, tools) are left to the view model (AIEditOperation.isDeferred).
//

import Foundation
import CoreGraphics

struct AIPlanOutcome {
    var applied = 0
    var failed: [String] = []
    var markers: [TimelineMarker] = []
    var touched: Set<UUID> = []
}

enum AIPlanExecutor {

    static func apply(_ steps: [AIPlanStep], to timeline: inout Timeline, styles: [UUID: EditingDNA],
                      context: EditContext) -> AIPlanOutcome {
        var outcome = AIPlanOutcome()
        for step in steps where step.isEnabled && !step.operation.isDeferred {
            var draft = timeline
            do {
                try run(step.operation, on: &draft, styles: styles, context: context, outcome: &outcome)
                timeline = draft
                outcome.applied += 1
            } catch {
                outcome.failed.append(step.summary + ": " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        TimelineEngine.finalize(&timeline, context: context)
        return outcome
    }

    private static func run(_ operation: AIEditOperation, on timeline: inout Timeline, styles: [UUID: EditingDNA],
                            context: EditContext, outcome: inout AIPlanOutcome) throws {
        switch operation {
        case .split(let time):
            let ids = TimelineEngine.clips(at: time, in: timeline).filter { clip in
                guard let t = TimelineEngine.trackIndex(of: clip.id, in: timeline) else { return false }
                return !timeline.tracks[t].isLocked && time > clip.start.seconds + context.frame && time < clip.end.seconds - context.frame
            }.map(\.id)
            guard !ids.isEmpty else { throw TimelineEditError.clipNotFound }
            outcome.touched.formUnion(try TimelineEngine.split(Set(ids), at: time, in: &timeline, context: context))

        case .trim(let id, let start, let end):
            if let start { try TimelineEngine.trim(id, edge: .start, to: start, ripple: false, in: &timeline, context: context) }
            if let end { try TimelineEngine.trim(id, edge: .end, to: end, ripple: false, in: &timeline, context: context) }
            outcome.touched.insert(id)

        case .delete(let ids, let ripple):
            try TimelineEngine.delete(Set(ids), ripple: ripple, in: &timeline, context: context)

        case .move(let id, let time):
            guard let track = TimelineEngine.trackIndex(of: id, in: timeline) else { throw TimelineEditError.clipNotFound }
            try TimelineEngine.move([ClipMove(clipID: id, newStart: time, destination: .existing(track))], in: &timeline, context: context)
            outcome.touched.insert(id)

        case .speed(let id, let rate):
            guard let clip = TimelineEngine.clip(id, in: timeline) else { throw TimelineEditError.clipNotFound }
            var speed = clip.speed
            speed.rate = rate
            speed.ramp = []
            try TimelineEngine.setSpeed(speed, forClip: id, in: &timeline, context: context)
            outcome.touched.insert(id)

        case .addTitle(let text, let start, let duration, let placement):
            var content = TextContent(text: text)
            content.style.sizeRatio = 0.06
            content.style.weight = .bold
            let length = max(context.frame, context.snap(duration))
            let begin = context.snap(start)
            var clip = Clip(name: CaptionBuilder.shortName(text), source: .text(content), start: TimeValue(seconds: begin),
                            duration: TimeValue(seconds: length))
            let y: Double = placement == .top ? 0.16 : placement == .center ? 0.5 : 0.82
            clip.transform.position = KeyframedValue(Vec2(x: 0.5, y: y))
            let track = TimelineEngine.freeTrack(.text, start: begin, end: begin + length, in: &timeline, context: context)
            let ids = try TimelineEngine.place([clip], onTrack: track, at: begin, mode: .overwrite, in: &timeline, context: context)
            outcome.touched.formUnion(ids)

        case .transition(let ids, let kind, let duration):
            var added = 0
            for id in ids {
                if (try? TimelineEngine.setTransition(kind, duration: duration, forClip: id, in: &timeline, context: context)) != nil {
                    added += 1
                }
            }
            guard added > 0 else { throw TimelineEditError.noPreviousClip }

        case .volume(let ids, let level):
            TimelineEngine.updateClips(Set(ids), in: &timeline) { clip in
                clip.audio.volume = KeyframedValue(level)
                clip.audio.isMuted = level <= 0.001
            }
            outcome.touched.formUnion(ids)

        case .color(let ids, let exposure, let contrast, let saturation, let temperature):
            func add(_ value: Double, _ delta: Double) -> Double { min(100, max(-100, value + delta)) }
            TimelineEngine.updateClips(Set(ids), in: &timeline) { clip in
                clip.color.exposure = add(clip.color.exposure, exposure)
                clip.color.contrast = add(clip.color.contrast, contrast)
                clip.color.saturation = add(clip.color.saturation, saturation)
                clip.color.temperature = add(clip.color.temperature, temperature)
            }
            outcome.touched.formUnion(ids)

        case .marker(let time, let name):
            outcome.markers.append(TimelineMarker(time: TimeValue(seconds: context.snap(time)), name: name,
                                                  color: RGBAColor(hex: 0xE3B04B)))

        case .style(let id):
            guard let dna = styles[id] else { throw TimelineEditError.clipNotFound }
            try EditingDNAApplier.apply(dna, options: DNAApplyOptions(), colorMatches: [:], beats: nil, to: &timeline, context: context)

        case .removeSilences, .normalizeAudio, .duckMusic, .stabilize, .cutToBeat, .openTool:
            break
        }
    }
}
