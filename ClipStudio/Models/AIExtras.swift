//
//  AIExtras.swift
//  ClipStudio — Models (Part 6 suggestions)
//
//  Data for the AI tools added after Part 5:
//  • caption translation (targets + structured result);
//  • the pre-publish hook check (input measured on device, report, fixes);
//  • smart shortening ("make it 30 seconds" keeping the most important speech);
//  • assistant plan history and assistant memory (learned preferences);
//  • generated voiceover settings.
//

import Foundation

// MARK: - Caption translation

struct TranslationTarget: Hashable, Identifiable {
    let code: String
    let title: String

    var id: String { code }

    static let all: [TranslationTarget] = [
        TranslationTarget(code: "en", title: "English"),
        TranslationTarget(code: "ar", title: "العربية"),
        TranslationTarget(code: "fr", title: "Français"),
        TranslationTarget(code: "es", title: "Español"),
        TranslationTarget(code: "tr", title: "Türkçe"),
        TranslationTarget(code: "ur", title: "اردو"),
        TranslationTarget(code: "hi", title: "हिन्दी"),
        TranslationTarget(code: "id", title: "Bahasa Indonesia"),
        TranslationTarget(code: "de", title: "Deutsch"),
        TranslationTarget(code: "ru", title: "Русский"),
        TranslationTarget(code: "zh-Hans", title: "中文"),
        TranslationTarget(code: "ja", title: "日本語"),
        TranslationTarget(code: "fa", title: "فارسی"),
        TranslationTarget(code: "pt", title: "Português")
    ]

    static func target(_ code: String) -> TranslationTarget? { all.first { $0.code == code } }

    /// Right-to-left scripts (caption layout keeps working; only used for labels).
    var isRightToLeft: Bool { ["ar", "ur", "fa"].contains(code) }
}

struct TranslationResult: Codable, Hashable {
    var translations: [String]
}

// MARK: - Hook check

/// What the first seconds of a project contain (measured on device).
struct HookInput: Hashable {
    var duration: Double
    /// First visible text (title or caption) start, timeline seconds.
    var firstTextTime: Double?
    var firstText: String
    /// First spoken word, timeline seconds.
    var firstSpeechTime: Double?
    /// Words spoken in the first 5 seconds.
    var openingWords: String
    /// Cuts on the main track inside the first 5 seconds.
    var cutTimes: [Double]
    /// Average loudness 0…1 of the first 2 s and of the rest.
    var openingLoudness: Double?
    var restLoudness: Double?
    var hasMusicAtStart: Bool
    /// The first visual clip starts later than 0 (black opening).
    var blackOpening: Double
}

enum HookAction: String, Codable, CaseIterable, Hashable {
    case none, addTitle, trimStart
}

struct HookSuggestion: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var action: HookAction = .none
    /// Text for `.addTitle`.
    var titleText: String = ""
    /// New start for `.trimStart` (seconds removed from the beginning).
    var trimTo: Double = 0

    enum CodingKeys: String, CodingKey { case text, action, titleText, trimTo }
}

extension HookSuggestion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        text = c.value(.text, default: "")
        action = (try? c.decode(HookAction.self, forKey: .action)) ?? .none
        titleText = c.value(.titleText, default: "")
        trimTo = c.value(.trimTo, default: 0.0)
    }
}

struct HookReport: Codable, Hashable {
    /// 0…100.
    var score: Double
    var verdict: String
    var strengths: [String]
    var problems: [String]
    var suggestions: [HookSuggestion]

    enum CodingKeys: String, CodingKey { case score, verdict, strengths, problems, suggestions }
}

extension HookReport {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = c.value(.score, default: 50.0)
        verdict = c.value(.verdict, default: "")
        strengths = c.value(.strengths, default: [String]())
        problems = c.value(.problems, default: [String]())
        suggestions = c.value(.suggestions, default: [HookSuggestion]())
    }

    var grade: String {
        switch score {
        case 80...: "قوي"
        case 60..<80: "جيد"
        case 40..<60: "متوسط"
        default: "ضعيف"
        }
    }
}

// MARK: - Smart shortening

struct ShortenSentence: Codable, Hashable, Identifiable {
    var index: Int
    var text: String
    /// Timeline seconds.
    var start: Double
    var end: Double

    var id: Int { index }
    var duration: Double { max(0, end - start) }
}

struct ShortenInput: Hashable {
    var sentences: [ShortenSentence]
    var target: Double
    var totalDuration: Double
}

struct ShortenResult: Codable, Hashable {
    var keep: [Int]
    var summary: String

    enum CodingKeys: String, CodingKey { case keep, summary }
}

extension ShortenResult {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keep = c.value(.keep, default: [Int]())
        summary = c.value(.summary, default: "")
    }
}

// MARK: - Assistant history & memory

struct PlanRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var request: String
    var plan: AIPlan
    var provider: AIProviderKind
    var result: String
}

struct AssistantMemoryData: Codable, Hashable {
    var isEnabled = true
    /// Preferences the user wrote ("عناويني دائمًا في الأعلى…").
    var notes = ""
    /// How often each choice was applied ("transition:fadeBlack", "placement:top", "speed:2"…).
    var counts: [String: Int] = [:]
}

// MARK: - Generated voiceover

enum VoiceoverEngine: String, CaseIterable, Identifiable, Hashable {
    case device, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: "صوت الجهاز"
        case .gemini: "صوت Gemini"
        }
    }
}

struct VoiceoverOptions: Hashable {
    var engine: VoiceoverEngine = .device
    /// BCP-47 language for device voices ("ar-SA").
    var language = "ar-SA"
    /// AVSpeechSynthesisVoice identifier (nil = best available for the language).
    var deviceVoice: String?
    /// 0.3…0.65 (AVSpeechUtterance rate scale; 0.5 ≈ natural).
    var rate: Double = 0.5
    var pitch: Double = 1
    /// Gemini prebuilt voice name.
    var geminiVoice = "Kore"
    /// Optional style instruction for Gemini ("بنبرة حماسية").
    var style = ""
}
