//
//  AccessibilityPrefs.swift
//  ClipStudio — Components (Part 6)
//
//  Accessibility options and helpers:
//  • larger trim handles on the timeline (easier to grab with a finger or
//    Switch Control);
//  • spoken descriptions of timeline clips for VoiceOver (kind, start, end,
//    speed, state);
//  • the system settings that matter (Reduce Motion, VoiceOver, Bold Text,
//    Larger Text) are read live where they are used.
//

import SwiftUI
import UIKit

enum AccessibilityPrefs {
    static let largeHandlesKey = "accessibility.largeHandles"

    /// "فيديو، من 0:03.20 إلى 0:08.00، سرعة ×2، مقفل"
    static func clipDescription(_ clip: Clip, trackKind: TrackKind, locked: Bool) -> String {
        var parts: [String] = [kindTitle(clip, trackKind: trackKind)]
        parts.append("من " + Fmt.durationPrecise(clip.start.seconds) + " إلى " + Fmt.durationPrecise(clip.end.seconds))
        if !clip.speed.isNormal {
            if clip.speed.isReversed { parts.append("معكوس") }
            if !clip.speed.ramp.isEmpty {
                parts.append("منحنى سرعة")
            } else if abs(clip.speed.rate - 1) > 0.001 {
                parts.append("سرعة ×" + Fmt.number(clip.speed.rate, digits: 2))
            }
        }
        if clip.transitionIn != nil { parts.append("بانتقال") }
        if !clip.isEnabled { parts.append("معطّل") }
        if clip.audio.isMuted && trackKind.carriesSound { parts.append("مكتوم") }
        if locked { parts.append("مقفل") }
        return parts.joined(separator: "، ")
    }

    static func kindTitle(_ clip: Clip, trackKind: TrackKind) -> String {
        switch clip.source {
        case .media: trackKind == .audio ? "صوت" : "فيديو"
        case .image: "صورة"
        case .freezeFrame: "إطار ثابت"
        case .text(let content): content.isCaption ? "ترجمة: " + String((content.caption?.composedText ?? content.text).prefix(40)) : "نص: " + String(content.text.prefix(40))
        case .shape: "شكل"
        case .sticker: "ملصق"
        case .solidColor: "لون"
        case .adjustment: "طبقة تعديل"
        }
    }
}

extension TrackKind {
    /// Tracks whose clips can carry sound.
    var carriesSound: Bool { self == .video || self == .overlay || self == .audio }
}
