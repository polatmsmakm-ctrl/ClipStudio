//
//  AIResponseValidator.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  Nothing the model returns is trusted as-is. Every answer is parsed into typed
//  values and checked against reality: references must exist, times are clamped
//  to the media / timeline, ranges must be long enough and not overlap, numbers
//  are kept in safe ranges, texts are trimmed to platform limits. Invalid pieces
//  are dropped (with a warning) instead of being applied.
//

import Foundation

enum AIValidationError: LocalizedError {
    case noJSON
    case empty

    var errorDescription: String? {
        switch self {
        case .noJSON: "لم يُرجع الذكاء الاصطناعي نتيجة صالحة. حاول مرة أخرى."
        case .empty: "لم يجد الذكاء الاصطناعي نتائج مناسبة."
        }
    }
}

enum AIResponseValidator {

    // MARK: JSON

    /// The JSON object in a reply (tolerates ```json fences and text around it).
    static func extractJSON(_ text: String) -> Data? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = body.range(of: "```", options: .backwards) { body = String(body[..<fence.lowerBound]) }
        }
        guard let open = body.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let closer: Character = body[open] == "{" ? "}" : "]"
        guard let close = body.lastIndex(of: closer), close > open else { return nil }
        return String(body[open...close]).data(using: .utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = extractJSON(text) else { throw AIValidationError.noJSON }
        do {
            return try JSONStore.makeDecoder().decode(T.self, from: data)
        } catch {
            throw AIValidationError.noJSON
        }
    }

    // MARK: Storyboard

    static func storyboard(_ raw: Storyboard, media: [AIMediaReference], targetDuration: Double) -> Storyboard {
        var result = raw
        result.title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.title.isEmpty { result.title = "قصة مصورة" }
        result.scenes = raw.scenes.prefix(40).compactMap { scene -> StoryboardScene? in
            var copy = scene
            copy.description = scene.description.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.onScreenText = String(scene.onScreenText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            copy.voiceover = String(scene.voiceover.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            copy.duration = min(60, max(0.5, scene.duration.isFinite ? scene.duration : 3))
            if let shot = scene.shot {
                copy.shot = validShot(shot, media: media, duration: copy.duration)
                if let valid = copy.shot, let item = media.first(where: { $0.ref.lowercased() == valid.mediaRef.lowercased() }),
                   item.kind != .image {
                    copy.duration = min(copy.duration, max(0.5, valid.end - valid.start))
                }
            }
            if copy.description.isEmpty && copy.onScreenText.isEmpty && copy.shot == nil { return nil }
            return copy
        }
        return result
    }

    static func validShot(_ shot: StoryboardShot, media: [AIMediaReference], duration: Double) -> StoryboardShot? {
        guard let item = media.first(where: { $0.ref.lowercased() == shot.mediaRef.lowercased() }) else { return nil }
        if item.kind == .image { return StoryboardShot(mediaRef: item.ref, start: 0, end: duration) }
        guard item.duration > 0.3, shot.start.isFinite, shot.end.isFinite else { return nil }
        var start = min(max(0, shot.start), item.duration - 0.3)
        var end = min(item.duration, max(shot.end, start + 0.3))
        if end - start < 0.3 {
            start = max(0, item.duration - 0.3)
            end = item.duration
        }
        return StoryboardShot(mediaRef: item.ref, start: start, end: end)
    }

    // MARK: Highlights

    static func highlights(_ raw: [HighlightMoment], duration: Double, count: Int, minimumLength: Double = 1.5,
                           maximumLength: Double = 120) -> [HighlightMoment] {
        let cleaned = raw.compactMap { moment -> HighlightMoment? in
            guard moment.start.isFinite, moment.end.isFinite else { return nil }
            var copy = moment
            copy.start = min(max(0, moment.start), duration)
            copy.end = min(max(copy.start, moment.end), duration)
            if copy.end - copy.start > maximumLength { copy.end = copy.start + maximumLength }
            guard copy.end - copy.start >= minimumLength else { return nil }
            copy.score = min(100, max(0, moment.score.isFinite ? moment.score : 50))
            copy.title = String(moment.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            if copy.title.isEmpty { copy.title = "لحظة مميزة" }
            copy.reason = String(moment.reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            return copy
        }
        var kept: [HighlightMoment] = []
        for moment in cleaned.sorted(by: { $0.score > $1.score }) {
            let overlaps = kept.contains { $0.start < moment.end - 0.1 && moment.start < $0.end - 0.1 }
            if !overlaps { kept.append(moment) }
            if kept.count >= max(1, count) { break }
        }
        return kept.sorted { $0.start < $1.start }
    }

    // MARK: Content

    static func posts(_ raw: [PlatformPost], platforms: [SocialPlatform]) -> [PlatformPost] {
        var result: [PlatformPost] = []
        for platform in platforms {
            guard var post = raw.first(where: { $0.platform == platform }) else { continue }
            post.title = String(post.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            var seen = Set<String>()
            post.hashtags = post.hashtags.compactMap { tag -> String? in
                let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "#", with: "")
                    .replacingOccurrences(of: " ", with: "_")
                guard !cleaned.isEmpty, !seen.contains(cleaned.lowercased()) else { return nil }
                seen.insert(cleaned.lowercased())
                return cleaned
            }
            post.hashtags = Array(post.hashtags.prefix(platform.hashtagLimit))
            let tagsLength = post.hashtags.reduce(0) { $0 + $1.count + 2 }
            let room = max(40, platform.captionLimit - tagsLength - post.title.count - 4)
            post.caption = String(post.caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(room))
            post.hook = String(post.hook.trimmingCharacters(in: .whitespacesAndNewlines).prefix(150))
            post.thumbnailText = String(post.thumbnailText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            result.append(post)
        }
        return result
    }

    // MARK: Transcript

    static func transcript(_ raw: [TranscriptSuggestion], wordCount: Int) -> [TranscriptSuggestion] {
        let valid = raw.compactMap { suggestion -> TranscriptSuggestion? in
            guard wordCount > 0 else { return nil }
            let a = min(suggestion.startWord, suggestion.endWord), b = max(suggestion.startWord, suggestion.endWord)
            guard a >= 0, b < wordCount, b - a < 60 else { return nil }
            var copy = suggestion
            copy.startWord = a
            copy.endWord = b
            copy.reason = String(suggestion.reason.prefix(160))
            return copy
        }.sorted { $0.startWord < $1.startWord }
        var merged: [TranscriptSuggestion] = []
        for suggestion in valid {
            if let last = merged.last, suggestion.startWord <= last.endWord {
                merged[merged.count - 1].endWord = max(last.endWord, suggestion.endWord)
            } else {
                merged.append(suggestion)
            }
        }
        return merged
    }

    // MARK: Style enrichment

    static func apply(_ enrichment: StyleEnrichment, to dna: inout EditingDNA) {
        func clamp(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(100, max(-100, value)) * 0.5
        }
        if let kind = enrichment.transitionKind.flatMap(TransitionKind.init(rawValue:)), kind != .none {
            dna.transitionKind = kind
            if let rate = enrichment.transitionRate, rate.isFinite {
                dna.transitionRate = max(dna.transitionRate, min(1, max(0, rate)))
            } else if dna.transitionRate < 0.1 {
                dna.transitionRate = 0.2
            }
        }
        if let id = enrichment.captionPreset, let preset = CaptionStylePreset.all.first(where: { $0.id == id }) {
            dna.captionStyle = preset.style
            dna.captionHighlight = preset.highlight
            dna.captionHighlightColor = preset.highlightColor
        }
        // A reference frame already drives color matching; numeric looks only fill in when there is none.
        if dna.referenceFrame == nil {
            var color = dna.color ?? ColorAdjustments()
            if let v = clamp(enrichment.exposure) { color.exposure = v }
            if let v = clamp(enrichment.contrast) { color.contrast = v }
            if let v = clamp(enrichment.saturation) { color.saturation = v }
            if let v = clamp(enrichment.temperature) { color.temperature = v }
            if let v = clamp(enrichment.vibrance) { color.vibrance = v }
            if !color.isNeutral { dna.color = color }
        }
        let mood = enrichment.mood.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mood.isEmpty { dna.origin += " • " + String(mood.prefix(40)) }
    }

    // MARK: Editing assistant

    private static func arguments(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func number(_ args: [String: Any], _ key: String) -> Double? {
        if let value = args[key] as? Double { return value.isFinite ? value : nil }
        if let value = args[key] as? Int { return Double(value) }
        if let value = args[key] as? NSNumber { return value.doubleValue }
        if let value = args[key] as? String { return Double(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func text(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func list(_ args: [String: Any], _ key: String) -> [String] {
        if let values = args[key] as? [String] { return values }
        if let value = args[key] as? String { return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return []
    }

    static func time(_ value: Double, frameRate: Double) -> String { Fmt.timecode(value, fps: frameRate) }

    /// Validated plan from function calls (unknown functions / references become warnings).
    static func plan(calls: [AIFunctionCall], text: String, context: AssistantContext, styles: [EditingDNA]) -> AIPlan {
        var steps: [AIPlanStep] = []
        var warnings: [String] = []
        let duration = max(0, context.duration)
        func clampTime(_ t: Double) -> Double { min(max(0, t), duration) }
        func resolve(_ refs: [String]) -> [UUID] {
            var ids: [UUID] = []
            for ref in refs {
                if let clip = context.clip(ref) { ids.append(clip.clipID) } else { warnings.append("المقطع «" + ref + "» غير موجود — تم تجاهله.") }
            }
            return ids
        }
        func name(_ id: UUID) -> String {
            guard let clip = context.clips.first(where: { $0.clipID == id }) else { return "مقطع" }
            return clip.ref + " «" + String(clip.name.prefix(20)) + "»"
        }
        let fps = context.frameRate

        for call in calls {
            let args = arguments(call.arguments)
            switch call.name {
            case "split_at":
                guard let t = number(args, "time") else { warnings.append("قص بدون وقت — تم تجاهله."); continue }
                let time = clampTime(t)
                steps.append(AIPlanStep(operation: .split(time: time), summary: "قص عند " + self.time(time, frameRate: fps)))
            case "trim_clip":
                guard let id = resolve([Self.text(args, "clip") ?? ""]).first, let clip = context.clips.first(where: { $0.clipID == id }) else { continue }
                var start = number(args, "start").map(clampTime)
                var end = number(args, "end").map(clampTime)
                if let s = start, s <= clip.start + 0.001 { start = s < clip.start - 0.001 ? s : nil }
                if let e = end, abs(e - clip.end) < 0.001 { end = nil }
                guard start != nil || end != nil else { warnings.append("قص " + clip.ref + " بدون تغيير — تم تجاهله."); continue }
                if (end ?? clip.end) - (start ?? clip.start) < 0.1 { warnings.append("قص " + clip.ref + " يجعل المقطع قصيرًا جدًا."); continue }
                var summary = "قص " + name(id)
                if let start { summary += " من " + self.time(start, frameRate: fps) }
                if let end { summary += " إلى " + self.time(end, frameRate: fps) }
                steps.append(AIPlanStep(operation: .trim(clip: id, start: start, end: end), summary: summary))
            case "delete_clips":
                let ids = resolve(list(args, "clips"))
                guard !ids.isEmpty else { continue }
                let ripple = (args["ripple"] as? Bool) ?? true
                steps.append(AIPlanStep(operation: .delete(clips: ids, ripple: ripple),
                                        summary: "حذف " + ids.map(name).joined(separator: "، ") + (ripple ? " وسد الفراغ" : "")))
            case "move_clip":
                guard let id = resolve([Self.text(args, "clip") ?? ""]).first, let t = number(args, "time") else { continue }
                steps.append(AIPlanStep(operation: .move(clip: id, to: max(0, t)), summary: "نقل " + name(id) + " إلى " + self.time(max(0, t), frameRate: fps)))
            case "set_speed":
                guard let id = resolve([Self.text(args, "clip") ?? ""]).first, let rate = number(args, "rate"), rate > 0 else { continue }
                let clamped = min(8, max(0.1, rate))
                steps.append(AIPlanStep(operation: .speed(clip: id, rate: clamped), summary: "سرعة " + name(id) + " ×" + Fmt.number(clamped, digits: 2)))
            case "add_title":
                guard let value = Self.text(args, "text"), !value.isEmpty else { continue }
                let start = clampTime(number(args, "start") ?? context.playhead)
                let length = min(30, max(0.5, number(args, "duration") ?? 3))
                let placement = Self.text(args, "placement").flatMap(TitlePlacement.init(rawValue:)) ?? .bottom
                steps.append(AIPlanStep(operation: .addTitle(text: String(value.prefix(200)), start: start, duration: length, placement: placement),
                                        summary: "عنوان «" + String(value.prefix(30)) + "» عند " + self.time(start, frameRate: fps)))
            case "add_transition":
                var ids = resolve(list(args, "clips"))
                if ids.isEmpty {
                    let main = context.clips.filter(\.onMainTrack).sorted { $0.start < $1.start }
                    ids = main.dropFirst().map(\.clipID)
                }
                guard !ids.isEmpty else { warnings.append("لا توجد قطعات لإضافة انتقال."); continue }
                let kind = Self.text(args, "kind").flatMap(TransitionKind.init(rawValue:)) ?? context.preferredTransition ?? .crossDissolve
                let length = min(2, max(0.1, number(args, "duration") ?? 0.5))
                steps.append(AIPlanStep(operation: .transition(clips: ids, kind: kind == .none ? .crossDissolve : kind, duration: length),
                                        summary: "انتقال «" + kind.title + "» (" + Fmt.int(ids.count) + ")"))
            case "set_volume":
                let ids = resolve(list(args, "clips"))
                guard !ids.isEmpty, let level = number(args, "level") else { continue }
                let clamped = min(2, max(0, level))
                steps.append(AIPlanStep(operation: .volume(clips: ids, level: clamped), summary: "الصوت " + Fmt.percent(clamped) + " لـ " + Fmt.int(ids.count) + " مقطع"))
            case "adjust_color":
                var ids = resolve(list(args, "clips"))
                if ids.isEmpty { ids = context.clips.filter(\.isPicture).map(\.clipID) }
                guard !ids.isEmpty else { continue }
                func value(_ key: String) -> Double { min(100, max(-100, number(args, key) ?? 0)) }
                let exposure = value("exposure"), contrast = value("contrast"), saturation = value("saturation"), temperature = value("temperature")
                guard exposure != 0 || contrast != 0 || saturation != 0 || temperature != 0 else { continue }
                steps.append(AIPlanStep(operation: .color(clips: ids, exposure: exposure, contrast: contrast, saturation: saturation, temperature: temperature),
                                        summary: "تعديل الألوان لـ " + Fmt.int(ids.count) + " لقطة"))
            case "add_marker":
                guard let t = number(args, "time") else { continue }
                let label = Self.text(args, "name").flatMap { $0.isEmpty ? nil : $0 } ?? "علامة"
                steps.append(AIPlanStep(operation: .marker(time: clampTime(t), name: String(label.prefix(40))),
                                        summary: "علامة «" + String(label.prefix(20)) + "» عند " + self.time(clampTime(t), frameRate: fps)))
            case "apply_style":
                guard let wanted = Self.text(args, "name"),
                      let style = styles.first(where: { $0.name == wanted }) ?? styles.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) else {
                    warnings.append("الأسلوب المطلوب غير موجود.")
                    continue
                }
                steps.append(AIPlanStep(operation: .style(id: style.id), summary: "تطبيق أسلوب «" + style.name + "»"))
            case "remove_silences":
                let minimum = min(5, max(0.3, number(args, "minimum_pause") ?? 0.8))
                steps.append(AIPlanStep(operation: .removeSilences(minimum: minimum), summary: "حذف الوقفات الأطول من " + Fmt.seconds(minimum, digits: 1)))
            case "normalize_audio":
                steps.append(AIPlanStep(operation: .normalizeAudio, summary: "تسوية مستوى الصوت"))
            case "duck_music":
                steps.append(AIPlanStep(operation: .duckMusic, summary: "خفض الموسيقى عند الكلام"))
            case "stabilize":
                guard let id = resolve([Self.text(args, "clip") ?? ""]).first else { continue }
                steps.append(AIPlanStep(operation: .stabilize(clip: id), summary: "تثبيت " + name(id)))
            case "cut_to_beat":
                let wanted = Int(number(args, "beats") ?? 2)
                let beats = [1, 2, 4, 8].min { abs($0 - wanted) < abs($1 - wanted) } ?? 2
                steps.append(AIPlanStep(operation: .cutToBeat(beats: beats), summary: "قص على الإيقاع كل " + Fmt.int(beats) + " ضربات"))
            case "open_tool":
                guard let tool = Self.text(args, "tool").flatMap(AssistantTool.init(rawValue:)) else { continue }
                steps.append(AIPlanStep(operation: .openTool(tool), summary: "فتح أداة: " + tool.title))
            default:
                warnings.append("أمر غير معروف: " + call.name)
            }
        }
        let explanation = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIPlan(explanation: explanation, steps: steps, warnings: warnings)
    }
}

extension AssistantTool {
    var title: String {
        switch self {
        case .captions: "الترجمة التلقائية"
        case .music: "الموسيقى والإيقاع"
        case .quality: "فحص الجودة"
        case .outputs: "نسخ بمقاسات أخرى"
        case .smartTools: "الأدوات الذكية"
        case .editingStyle: "أسلوب المونتاج"
        case .export: "التصدير"
        }
    }
}
