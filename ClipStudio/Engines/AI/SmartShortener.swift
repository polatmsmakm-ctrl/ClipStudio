//
//  SmartShortener.swift
//  ClipStudio — Engines/AI (Part 6 suggestions)
//
//  "Make it 30 seconds": the spoken words of the timeline are grouped into
//  sentences; Gemini (sentence texts + times only) or the on-device scorer
//  chooses which sentences to keep within the target length; everything else is
//  removed from every track at once with the text-based-editing engine (one undo
//  step). The user reviews / toggles sentences before anything is cut.
//

import Foundation

enum SmartShortener {
    /// Seconds kept around each kept sentence so words aren't clipped.
    static let padding = 0.12

    // MARK: Sentences

    /// Groups timeline words into sentences (punctuation, pauses ≥ 0.7 s, or long runs).
    static func sentences(from words: [TimelineWord], pause: Double = 0.7, maxWords: Int = 28,
                          maxLength: Double = 14) -> [ShortenSentence] {
        let sorted = words.sorted { $0.start < $1.start }
        var result: [ShortenSentence] = []
        var current: [TimelineWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            result.append(ShortenSentence(index: result.count, text: text, start: first.start, end: max(first.start + 0.05, last.end)))
            current = []
        }
        for word in sorted {
            if let last = current.last {
                let gap = word.start - last.end
                let length = word.end - (current.first?.start ?? word.start)
                if gap >= pause || current.count >= maxWords || length > maxLength { flush() }
            }
            current.append(word)
            if let mark = word.text.last, ".!?؟؛".contains(mark) { flush() }
        }
        flush()
        return result
    }

    // MARK: On-device selection

    /// Importance of each sentence: frequency of its content words, with a bonus for the
    /// opening (hook) and the closing sentence; fillers lower the score.
    static func scores(_ sentences: [ShortenSentence]) -> [Double] {
        guard !sentences.isEmpty else { return [] }
        func tokens(_ text: String) -> [String] {
            text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map { CaptionBuilder.normalized(String($0)) }
        }
        var frequency: [String: Int] = [:]
        for sentence in sentences {
            for token in Set(tokens(sentence.text)) where token.count >= 3 && !CaptionBuilder.isFiller(token) {
                frequency[token, default: 0] += 1
            }
        }
        var raw: [Double] = sentences.map { sentence in
            let all = tokens(sentence.text)
            guard !all.isEmpty else { return 0 }
            let content = Set(all.filter { $0.count >= 3 && !CaptionBuilder.isFiller($0) })
            let weight = content.reduce(0.0) { $0 + Double(frequency[$1] ?? 0) }
            let fillers = Double(all.filter(CaptionBuilder.isFiller).count)
            return max(0, weight / Double(all.count).squareRoot() - fillers * 0.5)
        }
        let top = raw.max() ?? 1
        raw[0] += 0.6 * max(top, 1)
        if raw.count > 1 { raw[raw.count - 1] += 0.3 * max(top, 1) }
        return raw
    }

    /// Sentences to keep so the kept speech fits `target` seconds (always at least one).
    static func select(_ sentences: [ShortenSentence], target: Double) -> Set<Int> {
        guard !sentences.isEmpty else { return [] }
        let values = scores(sentences)
        let order = sentences.indices.sorted { values[$0] != values[$1] ? values[$0] > values[$1] : $0 < $1 }
        var kept = Set<Int>()
        var total = 0.0
        for index in order {
            let length = sentences[index].duration + padding * 2
            if total + length <= target + 0.05 {
                kept.insert(sentences[index].index)
                total += length
            }
        }
        if kept.isEmpty, let best = order.first { kept.insert(sentences[best].index) }
        return kept
    }

    /// Trims a model's choice that runs long by dropping its least important sentences.
    static func fit(_ keep: Set<Int>, sentences: [ShortenSentence], target: Double) -> Set<Int> {
        let valid = keep.filter { index in sentences.contains { $0.index == index } }
        guard !valid.isEmpty else { return select(sentences, target: target) }
        let values = scores(sentences)
        var scoreByIndex: [Int: Double] = [:]
        for (position, sentence) in sentences.enumerated() { scoreByIndex[sentence.index] = values[position] }
        var kept = valid
        func length(_ set: Set<Int>) -> Double {
            sentences.filter { set.contains($0.index) }.reduce(0) { $0 + $1.duration + padding * 2 }
        }
        while length(kept) > target * 1.1 && kept.count > 1 {
            guard let weakest = kept.min(by: { (scoreByIndex[$0] ?? 0) < (scoreByIndex[$1] ?? 0) }) else { break }
            kept.remove(weakest)
        }
        return kept
    }

    // MARK: Cutting

    /// Timeline ranges to remove so only the kept sentences (padded) remain.
    static func removalSpans(keep: Set<Int>, sentences: [ShortenSentence], totalDuration: Double,
                             padding: Double = SmartShortener.padding) -> [TimeSpan] {
        let kept = sentences.filter { keep.contains($0.index) }.sorted { $0.start < $1.start }
        guard !kept.isEmpty, totalDuration > 0 else { return [] }
        var ranges: [TimeSpan] = []
        for sentence in kept {
            let span = TimeSpan(start: max(0, sentence.start - padding), end: min(totalDuration, sentence.end + padding))
            if let last = ranges.last, span.start <= last.end {
                ranges[ranges.count - 1].end = max(last.end, span.end)
            } else {
                ranges.append(span)
            }
        }
        var removals: [TimeSpan] = []
        var cursor = 0.0
        for range in ranges {
            if range.start - cursor > 0.1 { removals.append(TimeSpan(start: cursor, end: range.start)) }
            cursor = max(cursor, range.end)
        }
        if totalDuration - cursor > 0.1 { removals.append(TimeSpan(start: cursor, end: totalDuration)) }
        return removals
    }

    static func resultingDuration(totalDuration: Double, removals: [TimeSpan]) -> Double {
        max(0, totalDuration - removals.reduce(0) { $0 + $1.duration })
    }

    // MARK: AI request

    static func prompt(_ input: ShortenInput) -> String {
        var lines = ["المدة الحالية: " + Fmt.seconds(input.totalDuration, digits: 1) + "، المدة المطلوبة: " + Fmt.seconds(input.target, digits: 0) + ".",
                     "اختر أرقام الجمل التي تبقى (المجموع لا يتجاوز المدة المطلوبة)، وحافظ على المعنى والتسلسل وعلى جملة افتتاحية قوية:"]
        for sentence in input.sentences {
            lines.append("[" + String(sentence.index) + "] (" + Fmt.number(sentence.start, digits: 1) + "–" + Fmt.number(sentence.end, digits: 1) + "ث) " + sentence.text)
        }
        return lines.joined(separator: "\n")
    }

    static var schema: [String: Any] {
        let keep: [String: Any] = ["type": "ARRAY", "items": ["type": "INTEGER"] as [String: Any]]
        let summary: [String: Any] = ["type": "STRING"]
        let properties: [String: Any] = ["keep": keep, "summary": summary]
        return ["type": "OBJECT", "properties": properties, "required": ["keep", "summary"]]
    }

    static func local(_ input: ShortenInput) -> ShortenResult {
        let keep = select(input.sentences, target: input.target).sorted()
        return ShortenResult(keep: keep, summary: "اختيار على الجهاز حسب أهمية الكلمات وبداية ونهاية الكلام.")
    }

    @MainActor
    static func request(_ input: ShortenInput) -> AIRequest {
        AIRequest(task: .shorten, systemInstruction: AIPromptManager.system(for: .shorten, language: AISettings.shared.language),
                  messages: [AIMessage(role: .user, parts: [.text(prompt(input))])], responseSchema: schema,
                  temperature: 0.2, localInput: .shorten(input),
                  uploadSummary: "نص الكلام فقط مع أوقاته (بدون صوت أو صورة)")
    }

    /// Kept sentence indices (validated and fitted to the target).
    @MainActor
    static func choose(_ input: ShortenInput, forceLocal: Bool) async throws -> (keep: Set<Int>, response: AIResponse, summary: String) {
        let response = try await AIRequestRouter.shared.perform(request(input), forceLocal: forceLocal)
        let raw = try AIResponseValidator.decode(ShortenResult.self, from: response.text)
        let keep = fit(Set(raw.keep), sentences: input.sentences, target: input.target)
        return (keep: keep, response: response, summary: raw.summary)
    }
}
