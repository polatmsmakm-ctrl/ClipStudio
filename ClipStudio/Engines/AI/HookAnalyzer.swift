//
//  HookAnalyzer.swift
//  ClipStudio — Engines/AI (Part 6 suggestions)
//
//  Pre-publish check of the opening: is the hook strong in the first seconds?
//  The project is measured on device (first text, first spoken word, early cuts,
//  opening loudness, black opening). Gemini also looks at a few frames of the
//  first 3 seconds (after consent); the on-device checker scores the measurements.
//  Suggestions can carry a one-tap fix (add a title at the start, cut a slow start).
//

import Foundation
import CoreGraphics

enum HookAnalyzer {
    /// Times (timeline seconds) of the frames Gemini sees.
    static let frameTimes: [Double] = [0, 0.5, 1, 1.5, 2, 3]

    // MARK: On device

    static func local(_ input: HookInput) -> HookReport {
        var score = 55.0
        var strengths: [String] = []
        var problems: [String] = []
        var suggestions: [HookSuggestion] = []

        if input.blackOpening > 0.2 {
            score -= 15
            problems.append("الفيديو يبدأ بشاشة فارغة لمدة " + Fmt.seconds(input.blackOpening, digits: 1) + ".")
            suggestions.append(HookSuggestion(text: "احذف البداية الفارغة.", action: .trimStart, trimTo: input.blackOpening))
        }

        if let text = input.firstTextTime, text <= 1.5 {
            score += 15
            strengths.append("نص يظهر من أول " + Fmt.seconds(max(0, text), digits: 1) + ".")
        } else {
            score -= 10
            problems.append("لا يوجد نص على الشاشة في أول ثانيتين — كثيرون يشاهدون بدون صوت.")
            suggestions.append(HookSuggestion(text: "أضف عنوانًا قصيرًا في أول ثانيتين.", action: .addTitle,
                                              titleText: hookTitle(from: input)))
        }

        if let speech = input.firstSpeechTime {
            if speech <= 1 {
                score += 10
                strengths.append("الكلام يبدأ مباشرة.")
            } else if speech > 2.5 {
                score -= 10
                problems.append("الكلام يبدأ متأخرًا عند " + Fmt.seconds(speech, digits: 1) + ".")
                suggestions.append(HookSuggestion(text: "ابدأ الفيديو قبل الكلام بقليل.", action: .trimStart,
                                                  trimTo: max(0, speech - 0.3)))
            }
        }

        let earlyCuts = input.cutTimes.filter { $0 > 0.05 && $0 <= 5 }
        if !earlyCuts.isEmpty {
            score += 10
            strengths.append("تغيير لقطة خلال أول " + Fmt.seconds(earlyCuts.min() ?? 0, digits: 1) + ".")
        } else if input.duration > 8 {
            score -= 5
            problems.append("لقطة واحدة طويلة في البداية بدون تغيير.")
            suggestions.append(HookSuggestion(text: "قسّم اللقطة الأولى أو أضف تقريبًا خفيفًا لإحساس بالحركة."))
        }

        if let opening = input.openingLoudness, let rest = input.restLoudness, rest > 0.02 {
            if opening < rest * 0.6 {
                score -= 5
                problems.append("البداية أهدأ بكثير من باقي الفيديو.")
                suggestions.append(HookSuggestion(text: "ارفع صوت البداية أو ابدأ بالموسيقى/الكلام الأقوى."))
            } else {
                score += 5
                strengths.append("مستوى الصوت في البداية قوي.")
            }
        }
        if input.hasMusicAtStart {
            score += 5
            strengths.append("الموسيقى تبدأ مع الفيديو.")
        }

        let final = min(100, max(0, score))
        let report = HookReport(score: final, verdict: "", strengths: strengths, problems: problems, suggestions: suggestions)
        var result = report
        result.verdict = "الخطّاف " + report.grade + " (" + Fmt.int(Int(final.rounded())) + "/100)."
        return result
    }

    /// A short title for the opening: the first spoken words, the first text, or nothing.
    static func hookTitle(from input: HookInput) -> String {
        let words = input.openingWords.split(separator: " ").prefix(6).joined(separator: " ")
        if !words.isEmpty { return words }
        return String(input.firstText.prefix(40))
    }

    // MARK: Gemini

    static func prompt(_ input: HookInput) -> String {
        var lines = ["قيّم قوة بداية هذا الفيديو (الخطّاف) لمنصات الفيديو القصير. الصور المرفقة من الثواني: "
                     + frameTimes.map { Fmt.number($0, digits: 1) }.joined(separator: "، ") + "."]
        lines.append("مدة الفيديو: " + Fmt.seconds(input.duration, digits: 1))
        lines.append("أول نص على الشاشة: " + (input.firstTextTime.map { Fmt.seconds($0, digits: 1) + " «" + input.firstText + "»" } ?? "لا يوجد"))
        lines.append("أول كلمة منطوقة: " + (input.firstSpeechTime.map { Fmt.seconds($0, digits: 1) } ?? "لا يوجد كلام"))
        if !input.openingWords.isEmpty { lines.append("الكلام في أول 5 ثوانٍ: " + input.openingWords) }
        lines.append("القطعات في أول 5 ثوانٍ: " + (input.cutTimes.isEmpty ? "لا توجد" : input.cutTimes.map { Fmt.number($0, digits: 1) }.joined(separator: "، ")))
        if input.blackOpening > 0.05 { lines.append("بداية فارغة: " + Fmt.seconds(input.blackOpening, digits: 1)) }
        lines.append("أعط درجة 0–100، ونقاط القوة والمشاكل، واقتراحات عملية. action: addTitle (مع titleText قصير) أو trimStart (مع trimTo بالثواني) أو none.")
        return lines.joined(separator: "\n")
    }

    static var schema: [String: Any] {
        let string: [String: Any] = ["type": "STRING"]
        let number: [String: Any] = ["type": "NUMBER"]
        let strings: [String: Any] = ["type": "ARRAY", "items": string]
        let action: [String: Any] = ["type": "STRING", "enum": HookAction.allCases.map(\.rawValue)]
        let suggestionProperties: [String: Any] = ["text": string, "action": action, "titleText": string, "trimTo": number]
        let suggestion: [String: Any] = ["type": "OBJECT", "properties": suggestionProperties, "required": ["text", "action"]]
        let suggestions: [String: Any] = ["type": "ARRAY", "items": suggestion]
        let properties: [String: Any] = ["score": number, "verdict": string, "strengths": strings,
                                         "problems": strings, "suggestions": suggestions]
        return ["type": "OBJECT", "properties": properties,
                "required": ["score", "verdict", "strengths", "problems", "suggestions"]]
    }

    /// Clamps a model's report to safe values.
    static func validate(_ raw: HookReport, input: HookInput) -> HookReport {
        var report = raw
        report.score = min(100, max(0, raw.score.isFinite ? raw.score : 50))
        report.verdict = String(raw.verdict.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if report.verdict.isEmpty { report.verdict = "الخطّاف " + report.grade + "." }
        report.strengths = Array(raw.strengths.map { String($0.prefix(160)) }.filter { !$0.isEmpty }.prefix(6))
        report.problems = Array(raw.problems.map { String($0.prefix(160)) }.filter { !$0.isEmpty }.prefix(6))
        let maxTrim = max(0, min(5, input.duration - 1))
        report.suggestions = Array(raw.suggestions.compactMap { suggestion -> HookSuggestion? in
            var copy = suggestion
            copy.text = String(suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !copy.text.isEmpty else { return nil }
            switch suggestion.action {
            case .addTitle:
                copy.titleText = String(suggestion.titleText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                if copy.titleText.isEmpty { copy.titleText = hookTitle(from: input) }
                if copy.titleText.isEmpty { copy.action = .none }
            case .trimStart:
                copy.trimTo = min(maxTrim, max(0, suggestion.trimTo.isFinite ? suggestion.trimTo : 0))
                if copy.trimTo < 0.1 { copy.action = .none }
            case .none:
                break
            }
            return copy
        }.prefix(6))
        return report
    }

    @MainActor
    static func request(_ input: HookInput, frames: [AIPart]) -> AIRequest {
        AIRequest(task: .hookCheck, systemInstruction: AIPromptManager.system(for: .hookCheck, language: AISettings.shared.language),
                  messages: [AIMessage(role: .user, parts: [.text(prompt(input))] + frames)], responseSchema: schema,
                  temperature: 0.3, localInput: .hook(input),
                  uploadSummary: AIFeatureService.uploadSummary(frames: frames.count, hasText: true, videoSeconds: nil))
    }

    @MainActor
    static func check(_ input: HookInput, frames: [AIPart], forceLocal: Bool) async throws -> (report: HookReport, response: AIResponse) {
        let response = try await AIRequestRouter.shared.perform(request(input, frames: frames), forceLocal: forceLocal)
        let raw = try AIResponseValidator.decode(HookReport.self, from: response.text)
        return (report: validate(raw, input: input), response: response)
    }
}
