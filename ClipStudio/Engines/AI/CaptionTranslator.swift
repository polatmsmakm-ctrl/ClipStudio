//
//  CaptionTranslator.swift
//  ClipStudio — Engines/AI (Part 6 suggestions)
//
//  Translates the project's captions into another language. Gemini receives the
//  caption lines only (no audio / picture) in numbered batches and must return
//  the same number of lines; on iOS 18+ Apple's on-device Translation framework
//  is used when Gemini isn't set up (see CaptionTranslateSheet). The result is a
//  NEW captions track with the same timing and style — the original is kept.
//

import Foundation

enum CaptionTranslatorError: LocalizedError {
    case countMismatch
    case nothingToTranslate

    var errorDescription: String? {
        switch self {
        case .countMismatch: "رجعت الترجمة بعدد سطور مختلف — حاول مرة أخرى."
        case .nothingToTranslate: "لا توجد ترجمة نصية في المشروع لترجمتها."
        }
    }
}

enum CaptionTranslator {
    static let batchSize = 40

    /// Index ranges of the batches sent one after the other.
    static func batches(count: Int, size: Int = batchSize) -> [Range<Int>] {
        guard count > 0, size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { $0..<min(count, $0 + size) }
    }

    /// The model's lines, cleaned; nil when the count doesn't match.
    static func validate(_ lines: [String], expected: Int, originals: [String]) -> [String]? {
        guard lines.count == expected, originals.count == expected else { return nil }
        return zip(lines, originals).map { translated, original in
            let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\n", with: "\n")
            return cleaned.isEmpty ? original : String(cleaned.prefix(max(200, original.count * 3)))
        }
    }

    static func prompt(_ lines: [String], target: TranslationTarget) -> String {
        var text = "ترجم سطور الترجمة النصية التالية إلى " + target.title + " (" + target.code + "). "
        text += "أعد بالضبط " + String(lines.count) + " سطرًا بنفس الترتيب، سطر مقابل كل سطر، قصيرة وطبيعية ومناسبة للعرض على الشاشة. "
        text += "حافظ على فواصل الأسطر داخل السطر الواحد كـ \\n. لا تضف شروحًا.\n"
        let numbered = lines.enumerated().map { String($0.offset + 1) + ". " + $0.element.replacingOccurrences(of: "\n", with: "\\n") }
        return text + numbered.joined(separator: "\n")
    }

    static var schema: [String: Any] {
        let item: [String: Any] = ["type": "STRING"]
        let translations: [String: Any] = ["type": "ARRAY", "items": item]
        let properties: [String: Any] = ["translations": translations]
        return ["type": "OBJECT", "properties": properties, "required": ["translations"]]
    }

    /// Translates every line with Gemini (batches, one retry per batch).
    @MainActor
    static func translateWithGemini(_ lines: [String], target: TranslationTarget,
                                    progress: (Double) -> Void) async throws -> [String] {
        guard !lines.isEmpty else { throw CaptionTranslatorError.nothingToTranslate }
        var output: [String] = []
        let ranges = batches(count: lines.count)
        for (number, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let chunk = Array(lines[range])
            var translated: [String]?
            for attempt in 0..<2 where translated == nil {
                let request = AIRequest(task: .translation,
                                        systemInstruction: AIPromptManager.system(for: .translation, language: AISettings.shared.language),
                                        messages: [AIMessage(role: .user, parts: [.text(prompt(chunk, target: target))])],
                                        responseSchema: schema, temperature: attempt == 0 ? 0.2 : 0.0,
                                        uploadSummary: "نص الترجمة فقط")
                let response = try await AIRequestRouter.shared.perform(request)
                let result = try AIResponseValidator.decode(TranslationResult.self, from: response.text)
                translated = validate(result.translations, expected: chunk.count, originals: chunk)
            }
            guard let translated else { throw CaptionTranslatorError.countMismatch }
            output += translated
            progress(Double(number + 1) / Double(ranges.count))
        }
        return output
    }
}
