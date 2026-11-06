//
//  LocalAIProvider.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  The on-device provider: answers every AI task without network or key, using
//  the analyses the app already has (scene cuts, loudness, speech, transcripts,
//  NaturalLanguage keywords) and a command parser for the editing assistant. It
//  returns the same JSON / function calls as Gemini, so validation and the UI are
//  identical — results are simpler, never fake: every time and reference comes
//  from real measurements of the user's media.
//

import Foundation
import NaturalLanguage

protocol AIProvider {
    var kind: AIProviderKind { get }
    func generate(_ request: AIRequest, model: String) async throws -> AIResponse
}

struct GeminiProvider: AIProvider {
    let client: GeminiClient
    var kind: AIProviderKind { .gemini }

    func generate(_ request: AIRequest, model: String) async throws -> AIResponse {
        try await client.generate(model: model, request: request)
    }
}

enum LocalAIError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        "هذه المهمة تحتاج Gemini — أضف مفتاحك من الإعدادات ← الذكاء الاصطناعي."
    }
}

struct LocalAIProvider: AIProvider {
    var kind: AIProviderKind { .local }

    func generate(_ request: AIRequest, model: String) async throws -> AIResponse {
        guard let input = request.localInput else { throw LocalAIError.unsupported }
        var calls: [AIFunctionCall] = []
        let text: String
        switch input {
        case .storyboard(let value):
            text = try json(Self.storyboard(value))
        case .highlights(let value):
            text = try json(HighlightResult(highlights: Self.highlights(value)))
        case .content(let value):
            text = try json(Self.content(value))
        case .assistant(let command, let context):
            let parsed = LocalCommandParser.parse(command, context: context)
            calls = parsed.calls
            text = parsed.reply
        case .transcript(let words, let gaps):
            text = try json(TranscriptCleanupResult(suggestions: Self.transcript(words: words, gaps: gaps)))
        case .hook(let value):
            text = try json(HookAnalyzer.local(value))
        case .shorten(let value):
            text = try json(SmartShortener.local(value))
        }
        return AIResponse(provider: .local, model: "on-device", text: text, functionCalls: calls, usage: AIUsageInfo())
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
    }

    // MARK: Storyboard

    static func storyboard(_ input: StoryboardInput) -> Storyboard {
        var scenes: [StoryboardScene] = []
        var remaining = max(5, input.targetDuration)
        let visuals = input.media.filter { $0.kind != .audio }
        let idea = input.idea.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = String((idea.components(separatedBy: CharacterSet(charactersIn: ".!؟?\n")).first ?? idea).prefix(40))

        // Candidate shots: shot middles of each video, whole photos.
        var shots: [StoryboardShot] = []
        for item in visuals {
            if item.kind == .image {
                shots.append(StoryboardShot(mediaRef: item.ref, start: 0, end: 3))
                continue
            }
            let times = AIMediaPreparer.sampleTimes(duration: item.duration, count: max(1, min(4, Int(item.duration / 4))),
                                                    cuts: item.sceneCuts)
            for time in times {
                let length = min(3.5, item.duration)
                let start = min(max(0, time - length / 2), max(0, item.duration - length))
                shots.append(StoryboardShot(mediaRef: item.ref, start: start, end: start + length))
            }
        }
        guard !shots.isEmpty else {
            return Storyboard(title: headline.isEmpty ? "قصة مصورة" : headline, summary: "لا توجد وسائط — أضف صورًا أو فيديوهات.",
                              musicMood: input.tone, scenes: [])
        }
        // Interleave media so consecutive shots come from different files.
        var byMedia: [String: [StoryboardShot]] = [:]
        for shot in shots { byMedia[shot.mediaRef, default: []].append(shot) }
        var ordered: [StoryboardShot] = []
        let refs = visuals.map(\.ref)
        var round = 0
        while ordered.count < shots.count && round < 50 {
            for ref in refs where (byMedia[ref]?.count ?? 0) > round { ordered.append(byMedia[ref]![round]) }
            round += 1
        }
        for (index, shot) in ordered.enumerated() {
            guard remaining > 0.4 else { break }
            let length = min(shot.end - shot.start, remaining)
            let purpose: StoryboardPurpose = index == 0 ? .hook : (remaining - length < 0.5 ? .outro : .main)
            let item = visuals.first { $0.ref == shot.mediaRef }
            scenes.append(StoryboardScene(purpose: purpose,
                                          description: (item?.kind == .image ? "صورة «" : "لقطة من «") + (item?.name ?? shot.mediaRef) + "»",
                                          duration: length,
                                          onScreenText: index == 0 ? headline : "",
                                          voiceover: "",
                                          shot: StoryboardShot(mediaRef: shot.mediaRef, start: shot.start, end: shot.start + length)))
            remaining -= length
        }
        return Storyboard(title: headline.isEmpty ? "قصة مصورة" : headline,
                          summary: "قصة مقترحة على الجهاز من " + Fmt.int(visuals.count) + " ملف — عدّل المشاهد كما تحب.",
                          musicMood: input.tone, scenes: scenes)
    }

    // MARK: Highlights

    static func highlights(_ input: HighlightsInput) -> [HighlightMoment] {
        let duration = input.media.duration
        guard duration > 1 else { return [] }
        let length = min(max(2, input.targetLength), duration)
        let rate = 4.0
        func loudness(_ a: Double, _ b: Double) -> Double {
            guard !input.loudness.isEmpty else { return 0.3 }
            let i0 = max(0, Int(a * rate)), i1 = min(input.loudness.count, max(i0 + 1, Int(b * rate)))
            guard i0 < i1 else { return 0 }
            return input.loudness[i0..<i1].reduce(0, +) / Double(i1 - i0)
        }
        func speech(_ a: Double, _ b: Double) -> Double {
            let covered = input.speech.reduce(0.0) { $0 + max(0, min(b, $1.end) - max(a, $1.start)) }
            return covered / max(0.1, b - a)
        }
        func cuts(_ a: Double, _ b: Double) -> Double {
            Double(input.sceneCuts.filter { $0 > a && $0 < b }.count) / max(1, (b - a) / 2)
        }
        let peak = max(0.01, input.loudness.max() ?? 1)
        var candidates: [HighlightMoment] = []
        var start = 0.0
        while start + length <= duration + 0.01 {
            let end = min(duration, start + length)
            let l = loudness(start, end) / peak, s = speech(start, end), c = min(1, cuts(start, end))
            let score = (0.5 * l + 0.3 * s + 0.2 * c) * 100
            let reason: String
            if l >= s && l >= c { reason = "صوت مرتفع وحماس" } else if s >= c { reason = "كلام واضح" } else { reason = "حركة وتغيّر لقطات" }
            // Snap edges to nearby cuts for cleaner moments.
            var a = start, b = end
            if let near = input.sceneCuts.min(by: { abs($0 - a) < abs($1 - a) }), abs(near - a) <= 1 { a = near }
            if let near = input.sceneCuts.min(by: { abs($0 - b) < abs($1 - b) }), abs(near - b) <= 1, near - a >= 1.5 { b = near }
            candidates.append(HighlightMoment(start: a, end: b, score: score, title: "لحظة " + Fmt.timecode(a, fps: 1), reason: reason))
            start += 1
        }
        return AIResponseValidator.highlights(candidates, duration: duration, count: input.count)
    }

    // MARK: Content

    static func keywords(_ text: String, limit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        var counts: [String: Int] = [:]
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            let word = String(text[range]).trimmingCharacters(in: .punctuationCharacters)
            guard word.count >= 3, !CaptionBuilder.isFiller(word) else { return true }
            if tag == .noun || tag == .personalName || tag == .placeName || tag == .organizationName || tag == .adjective {
                counts[word, default: 0] += tag == .noun ? 2 : 1
            }
            return true
        }
        if counts.isEmpty {
            for word in text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init) where word.count >= 4 {
                counts[word, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    static func content(_ input: ContentInput) -> ContentPack {
        let source = ([input.projectName] + input.onScreenText + [input.spokenText]).joined(separator: ". ")
        let keys = keywords(source, limit: 10)
        let sentences = input.spokenText.components(separatedBy: CharacterSet(charactersIn: ".!؟?\n")).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { $0.count > 8 }
        let hook = sentences.first.map { String($0.prefix(80)) } ?? (input.onScreenText.first ?? input.projectName)
        let summary = sentences.prefix(2).joined(separator: ". ")
        let title = input.onScreenText.first(where: { $0.count > 3 }) ?? input.projectName
        let posts = input.platforms.map { platform -> PlatformPost in
            var tags = keys.map { $0.replacingOccurrences(of: " ", with: "_") }
            switch platform {
            case .tiktok: tags += ["تيك_توك", "اكسبلور"]
            case .instagram: tags += ["ريلز", "اكسبلور"]
            case .youtube, .youtubeShorts: tags += ["يوتيوب"]
            case .snapchat, .x: break
            }
            let call = platform == .youtube ? "اشترك ليصلك الجديد." : "شاركه مع من يهمه الأمر."
            let caption = [summary.isEmpty ? hook : summary, call].filter { !$0.isEmpty }.joined(separator: "\n")
            return PlatformPost(platform: platform, title: String(title.prefix(90)), caption: caption, hashtags: tags,
                                hook: hook, thumbnailText: String((keys.prefix(2).joined(separator: " ")).prefix(30)))
        }
        return ContentPack(projectID: UUID(), createdAt: Date(), provider: .local, keywords: keys,
                           posts: AIResponseValidator.posts(posts, platforms: input.platforms))
    }

    // MARK: Transcript

    static func transcript(words: [String], gaps: [Double]) -> [TranscriptSuggestion] {
        var result: [TranscriptSuggestion] = []
        let normalized = words.map(CaptionBuilder.normalized)
        var index = 0
        while index < words.count {
            if CaptionBuilder.isFiller(words[index]) {
                result.append(TranscriptSuggestion(startWord: index, endWord: index, kind: .filler, reason: "كلمة حشو"))
                index += 1
                continue
            }
            // Repeated phrase of 1–3 words ("أنا أنا", "في البيت في البيت").
            var matched = false
            for size in stride(from: 3, through: 1, by: -1) where index + 2 * size <= words.count {
                let a = normalized[index..<(index + size)], b = normalized[(index + size)..<(index + 2 * size)]
                if !a.contains(where: \.isEmpty), Array(a) == Array(b) {
                    result.append(TranscriptSuggestion(startWord: index, endWord: index + size - 1, kind: .repetition,
                                                       reason: "تكرار «" + a.joined(separator: " ") + "»"))
                    index += size
                    matched = true
                    break
                }
            }
            if !matched { index += 1 }
        }
        for (i, gap) in gaps.enumerated() where gap >= 1.2 && i < words.count {
            result.append(TranscriptSuggestion(startWord: i, endWord: i, kind: .pause, reason: "وقفة " + Fmt.seconds(gap, digits: 1)))
        }
        return result.sorted { $0.startWord < $1.startWord }
    }
}

// MARK: - Assistant command parser (offline)

enum LocalCommandParser {
    static func latinDigits(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669: result.unicodeScalars.append(UnicodeScalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: result.unicodeScalars.append(UnicodeScalar(scalar.value - 0x06F0 + 0x30)!)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result.replacingOccurrences(of: "٫", with: ".")
    }

    static func numbers(_ text: String) -> [Double] {
        let regex = try? NSRegularExpression(pattern: "\\d+(?:\\.\\d+)?")
        let range = NSRange(text.startIndex..., in: text)
        return regex?.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { Double(text[$0]) }
        } ?? []
    }

    static func quoted(_ text: String) -> String? {
        let regex = try? NSRegularExpression(pattern: "[\"«“']([^\"»”']+)[\"»”']")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex?.firstMatch(in: text, range: range), let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Clip refs mentioned as "c3", "المقطع 3", "clip 3", or the selection.
    static func clipRefs(_ text: String, context: AssistantContext) -> [String] {
        var refs: [String] = []
        let regex = try? NSRegularExpression(pattern: "(?:\\bc|المقطع|مقطع|clip)\\s*(\\d+)", options: [.caseInsensitive])
        let range = NSRange(text.startIndex..., in: text)
        for match in regex?.matches(in: text, range: range) ?? [] {
            if let r = Range(match.range(at: 1), in: text) { refs.append("c" + text[r]) }
        }
        if refs.isEmpty, contains(text, ["المحدد", "المختار", "selected", "هذا المقطع", "this clip"]) || !context.selectedRefs.isEmpty && refs.isEmpty {
            refs = context.selectedRefs
        }
        return refs.filter { context.clip($0) != nil }
    }

    static func contains(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func call(_ name: String, _ args: [String: Any] = [:]) -> AIFunctionCall {
        AIFunctionCall(name: name, arguments: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8))
    }

    static func parse(_ raw: String, context: AssistantContext) -> (calls: [AIFunctionCall], reply: String) {
        let text = latinDigits(raw)
        let values = numbers(text)
        var calls: [AIFunctionCall] = []
        let clips = clipRefs(text, context: context)
        // Numbers that aren't clip indices (times, rates…).
        var free = values
        for ref in clips { if let n = Double(ref.dropFirst()), let i = free.firstIndex(of: n) { free.remove(at: i) } }

        if contains(text, ["صمت", "الوقفات", "السكتات", "silence", "pauses"]) {
            calls.append(call("remove_silences", ["minimum_pause": free.first ?? 0.8]))
        } else if contains(text, ["احذف", "امسح", "شيل", "delete", "remove"]), !clips.isEmpty {
            calls.append(call("delete_clips", ["clips": clips, "ripple": true]))
        }
        if contains(text, ["قص عند", "قسم", "قسّم", "اقسم", "split"]), let t = free.first ?? Optional(context.playhead) {
            calls.append(call("split_at", ["time": t]))
        }
        if contains(text, ["سرع", "سرّع", "سرعة", "speed", "faster"]) {
            let rate = free.first ?? 2
            for ref in clips.isEmpty ? context.selectedRefs : clips { calls.append(call("set_speed", ["clip": ref, "rate": rate])) }
        } else if contains(text, ["بطئ", "بطّئ", "ابطئ", "تصوير بطيء", "slow"]) {
            for ref in clips.isEmpty ? context.selectedRefs : clips { calls.append(call("set_speed", ["clip": ref, "rate": free.first ?? 0.5])) }
        }
        if contains(text, ["عنوان", "نص", "اكتب", "title", "text"]), let value = quoted(text) {
            let placement = contains(text, ["فوق", "أعلى", "top"]) ? "top" : contains(text, ["وسط", "منتصف", "center"]) ? "center" : "bottom"
            calls.append(call("add_title", ["text": value, "start": free.first ?? context.playhead, "duration": free.dropFirst().first ?? 3,
                                            "placement": placement]))
        }
        if contains(text, ["انتقال", "انتقالات", "transition"]) {
            var kind = context.preferredTransition ?? TransitionKind.crossDissolve
            if contains(text, ["أسود", "اسود", "black"]) { kind = .fadeBlack }
            else if contains(text, ["أبيض", "ابيض", "white", "فلاش", "flash"]) { kind = .flash }
            else if contains(text, ["تكبير", "زووم", "zoom"]) { kind = .zoomIn }
            else if contains(text, ["مسح", "wipe"]) { kind = .wipeLeft }
            else if contains(text, ["انزلاق", "سلايد", "slide"]) { kind = .slideLeft }
            calls.append(call("add_transition", ["clips": clips, "kind": kind.rawValue, "duration": free.first.map { min(2, $0) } ?? 0.5]))
        }
        if contains(text, ["علامة", "ماركر", "marker"]) {
            calls.append(call("add_marker", ["time": free.first ?? context.playhead, "name": quoted(text) ?? "علامة"]))
        }
        if contains(text, ["ثبت", "ثبّت", "تثبيت", "اهتزاز", "stabiliz"]) {
            for ref in clips.isEmpty ? context.selectedRefs : clips { calls.append(call("stabilize", ["clip": ref])) }
        }
        if contains(text, ["إيقاع", "الايقاع", "الإيقاع", "beat"]) {
            calls.append(call("cut_to_beat", ["beats": Int(free.first ?? 2)]))
        }
        if contains(text, ["كتم", "mute"]) {
            calls.append(call("set_volume", ["clips": clips.isEmpty ? context.selectedRefs : clips, "level": 0]))
        } else if contains(text, ["ارفع الصوت", "علّ الصوت", "louder"]) {
            calls.append(call("set_volume", ["clips": clips.isEmpty ? context.selectedRefs : clips, "level": 1.5]))
        } else if contains(text, ["اخفض الصوت", "وطّ الصوت", "quieter"]) {
            calls.append(call("set_volume", ["clips": clips.isEmpty ? context.selectedRefs : clips, "level": 0.5]))
        }
        var color: [String: Any] = [:]
        if contains(text, ["أفتح", "افتح الصورة", "سطوع", "brighter"]) { color["exposure"] = 25 }
        if contains(text, ["أغمق", "اغمق", "darker"]) { color["exposure"] = -25 }
        if contains(text, ["أبيض وأسود", "ابيض واسود", "black and white"]) { color["saturation"] = -100 }
        else if contains(text, ["ألوان أقوى", "تشبع", "vivid", "saturat"]) { color["saturation"] = 20 }
        if contains(text, ["دافئ", "دافي", "warm"]) { color["temperature"] = 20 }
        if contains(text, ["بارد", "cool", "cold"]) { color["temperature"] = -20 }
        if contains(text, ["تباين", "contrast"]) { color["contrast"] = 20 }
        if !color.isEmpty {
            color["clips"] = clips
            calls.append(call("adjust_color", color))
        }
        if contains(text, ["وحّد الصوت", "وحد الصوت", "تسوية", "normaliz"]) { calls.append(call("normalize_audio")) }
        if contains(text, ["اخفض الموسيقى", "خفض الموسيقى", "duck"]) { calls.append(call("duck_music")) }
        if contains(text, ["أسلوب", "اسلوب", "style"]),
           let style = context.styleNames.first(where: { text.localizedCaseInsensitiveContains($0) }) {
            calls.append(call("apply_style", ["name": style]))
        }
        if contains(text, ["ترجمة", "captions", "subtitles"]) { calls.append(call("open_tool", ["tool": "captions"])) }
        if contains(text, ["فحص", "check quality"]) { calls.append(call("open_tool", ["tool": "quality"])) }
        if contains(text, ["مقاسات", "مقاس", "أبعاد", "formats"]) { calls.append(call("open_tool", ["tool": "outputs"])) }
        if contains(text, ["صدّر", "صدر", "تصدير", "export"]) { calls.append(call("open_tool", ["tool": "export"])) }

        if calls.isEmpty {
            return ([], "لم أفهم الطلب على الجهاز. جرّب مثلًا: «احذف الصمت»، «قص عند 12»، «سرّع المقطع 3 ×2»، «أضف عنوان \"مرحبًا\" فوق»، «انتقال تلاشي بين كل المقاطع»، «ثبّت المقطع 2». وللطلبات الحرة فعّل Gemini من الإعدادات.")
        }
        return (calls, "خطة من المساعد على الجهاز — راجعها قبل التطبيق.")
    }
}
