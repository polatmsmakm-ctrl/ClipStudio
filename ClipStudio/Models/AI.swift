//
//  AI.swift
//  ClipStudio — Models (Part 5)
//
//  Data for the AI layer:
//  • requests / responses that every provider understands (Gemini in the cloud
//    with the user's own key, or the on-device provider);
//  • results of the AI tools: storyboards, highlights, content packs, editing-
//    assistant plans, transcript clean-up suggestions and style enrichment.
//  Results are plain Codable values so they can be validated, cached, edited by
//  the user and applied as normal (undoable) edits.
//  Part 6: translation, hook check and smart shortening tasks; plans are Codable
//  (plan history); the assistant context carries the learned preferred transition.
//

import Foundation

// MARK: - Tasks & providers

enum AITask: String, Codable, CaseIterable, Hashable {
    case storyboard, highlights, content, assistant, transcriptCleanup, styleEnrichment, connectionTest
    // Part 6
    case translation, hookCheck, shorten

    var title: String {
        switch self {
        case .storyboard: "القصة المصورة"
        case .highlights: "أفضل اللقطات"
        case .content: "استوديو المحتوى"
        case .assistant: "مساعد المونتاج"
        case .transcriptCleanup: "تنظيف الكلام"
        case .styleEnrichment: "تحسين الأسلوب"
        case .connectionTest: "اختبار الاتصال"
        case .translation: "ترجمة الترجمة النصية"
        case .hookCheck: "فحص الخطّاف"
        case .shorten: "الاختصار الذكي"
        }
    }

    /// Tasks the on-device provider can also do (with simpler results).
    var hasLocalFallback: Bool { self != .styleEnrichment && self != .connectionTest && self != .translation }
}

enum AIProviderKind: String, Codable, Hashable {
    case gemini, local

    var title: String { self == .gemini ? "Gemini (سحابي)" : "على الجهاز" }
}

/// One piece of a request.
enum AIPart: Hashable {
    case text(String)
    /// Small inline media (JPEG frames).
    case inlineData(mimeType: String, data: Data)
    /// Media uploaded with the Gemini Files API.
    case fileData(mimeType: String, uri: String)
}

struct AIMessage: Hashable {
    enum Role: String, Hashable { case user, model }
    var role: Role
    var parts: [AIPart]
}

/// A function the model may call (editing assistant).
struct AIFunctionDeclaration {
    var name: String
    var description: String
    /// OpenAPI-style schema of the arguments (nil = no arguments).
    var parameters: [String: Any]?
}

struct AIFunctionCall: Hashable {
    var name: String
    /// Arguments as JSON data.
    var arguments: Data
}

struct AIRequest {
    var task: AITask
    var systemInstruction: String
    var messages: [AIMessage]
    /// JSON schema for structured output (nil = free text / function calls).
    var responseSchema: [String: Any]?
    var functions: [AIFunctionDeclaration] = []
    var temperature: Double = 0.4
    /// Input the on-device provider uses instead of the prompt.
    var localInput: AILocalInput?
    /// Short Arabic description of what media leaves the device (shown before upload).
    var uploadSummary: String?

    var containsMedia: Bool {
        messages.contains { $0.parts.contains { part in
            if case .text = part { return false }
            return true
        } }
    }

    /// Stable key for the response cache.
    func cacheKey(model: String) -> String {
        var hasher = StableHasher()
        hasher.add(task.rawValue)
        hasher.add(model)
        hasher.add(systemInstruction)
        for message in messages {
            hasher.add(message.role.rawValue)
            for part in message.parts {
                switch part {
                case .text(let text): hasher.add("t:" + text)
                case .inlineData(let mime, let data): hasher.add("i:" + mime); hasher.add(data)
                case .fileData(let mime, let uri): hasher.add("f:" + mime + uri)
                }
            }
        }
        if let schema = responseSchema, let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
            hasher.add(data)
        }
        hasher.add(functions.map(\.name).joined(separator: ","))
        hasher.add(String(temperature))
        return hasher.hex
    }
}

/// Deterministic FNV-1a 64-bit hash (Swift's Hasher is randomly seeded per launch).
struct StableHasher {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ string: String) { add(Data(string.utf8)) }

    mutating func add(_ data: Data) {
        for byte in data {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        value ^= 0xff
        value = value &* 0x0000_0100_0000_01B3
    }

    var hex: String { String(format: "%016llx", value) }
}

struct AIUsageInfo: Codable, Hashable {
    var promptTokens = 0
    var outputTokens = 0
    var totalTokens: Int { promptTokens + outputTokens }
}

struct AIResponse {
    var provider: AIProviderKind
    var model: String
    var text: String
    var functionCalls: [AIFunctionCall]
    var usage: AIUsageInfo
    var fromCache: Bool = false
    /// Shown to the user (e.g. why the on-device provider answered instead).
    var note: String? = nil
}

/// Structured input for the on-device provider.
enum AILocalInput {
    case storyboard(StoryboardInput)
    case highlights(HighlightsInput)
    case content(ContentInput)
    case assistant(command: String, context: AssistantContext)
    case transcript(words: [String], gaps: [Double])
    // Part 6
    case hook(HookInput)
    case shorten(ShortenInput)
}

// MARK: - Storyboard

struct StoryboardInput {
    var idea: String
    var targetDuration: Double
    var media: [AIMediaReference]
    var tone: String
}

/// A library item shown to the AI as "m1", "m2"…
struct AIMediaReference: Hashable, Codable {
    var ref: String
    var assetID: UUID
    var kind: MediaKind
    var name: String
    var duration: Double
    /// Shot boundaries (source seconds) when known.
    var sceneCuts: [Double] = []
    /// Spoken words when a transcript exists.
    var transcript: String = ""
}

enum StoryboardPurpose: String, Codable, CaseIterable, Hashable {
    case hook, intro, main, detail, transition, cta, outro

    var title: String {
        switch self {
        case .hook: "الخطّاف"
        case .intro: "المقدمة"
        case .main: "المحتوى"
        case .detail: "تفاصيل"
        case .transition: "انتقال"
        case .cta: "دعوة لإجراء"
        case .outro: "الخاتمة"
        }
    }
}

struct StoryboardShot: Codable, Hashable {
    var mediaRef: String
    var start: Double
    var end: Double
}

struct StoryboardScene: Codable, Hashable, Identifiable {
    var id = UUID()
    var purpose: StoryboardPurpose
    var description: String
    var duration: Double
    var onScreenText: String
    var voiceover: String
    var shot: StoryboardShot?

    enum CodingKeys: String, CodingKey { case purpose, description, duration, onScreenText, voiceover, shot }
}

extension StoryboardScene {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        purpose = (try? c.decode(StoryboardPurpose.self, forKey: .purpose)) ?? .main
        description = c.value(.description, default: "")
        duration = c.value(.duration, default: 3.0)
        onScreenText = c.value(.onScreenText, default: "")
        voiceover = c.value(.voiceover, default: "")
        shot = try? c.decodeIfPresent(StoryboardShot.self, forKey: .shot)
    }
}

struct Storyboard: Codable, Hashable {
    var title: String
    var summary: String
    var musicMood: String
    var scenes: [StoryboardScene]

    var duration: Double { scenes.reduce(0) { $0 + $1.duration } }
}

// MARK: - Highlights

struct HighlightsInput {
    var media: AIMediaReference
    var count: Int
    var targetLength: Double
    var sceneCuts: [Double]
    /// Loudness 0…1 at 4 values per second.
    var loudness: [Double]
    var speech: [TimeSpan]
}

struct HighlightMoment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    /// 0…100.
    var score: Double
    var title: String
    var reason: String

    enum CodingKeys: String, CodingKey { case start, end, score, title, reason }

    var duration: Double { max(0, end - start) }
}

extension HighlightMoment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        start = c.value(.start, default: 0.0)
        end = c.value(.end, default: 0.0)
        score = c.value(.score, default: 50.0)
        title = c.value(.title, default: "")
        reason = c.value(.reason, default: "")
    }
}

struct HighlightResult: Codable, Hashable {
    var highlights: [HighlightMoment]
}

// MARK: - Content Studio

enum SocialPlatform: String, Codable, CaseIterable, Identifiable, Hashable {
    case tiktok, instagram, youtube, youtubeShorts, snapchat, x

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiktok: "تيك توك"
        case .instagram: "إنستقرام"
        case .youtube: "يوتيوب"
        case .youtubeShorts: "يوتيوب شورتس"
        case .snapchat: "سناب شات"
        case .x: "X"
        }
    }

    var symbol: String {
        switch self {
        case .tiktok: "music.note"
        case .instagram: "camera"
        case .youtube: "play.rectangle"
        case .youtubeShorts: "play.rectangle.on.rectangle"
        case .snapchat: "bubble.left.and.bubble.right"
        case .x: "text.bubble"
        }
    }

    /// Practical caption length limit.
    var captionLimit: Int {
        switch self {
        case .tiktok: 2200
        case .instagram: 2200
        case .youtube: 5000
        case .youtubeShorts: 5000
        case .snapchat: 250
        case .x: 280
        }
    }

    var hashtagLimit: Int {
        switch self {
        case .instagram: 30
        case .youtube, .youtubeShorts: 15
        case .tiktok: 10
        case .snapchat: 3
        case .x: 3
        }
    }
}

struct ContentInput {
    var projectName: String
    var duration: Double
    var spokenText: String
    var onScreenText: [String]
    var platforms: [SocialPlatform]
    var tone: String
    var language: String
}

struct PlatformPost: Codable, Hashable, Identifiable {
    var platform: SocialPlatform
    var title: String
    var caption: String
    var hashtags: [String]
    var hook: String
    var thumbnailText: String

    var id: String { platform.rawValue }

    enum CodingKeys: String, CodingKey { case platform, title, caption, hashtags, hook, thumbnailText }
}

extension PlatformPost {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = (try? c.decode(SocialPlatform.self, forKey: .platform)) ?? .instagram
        title = c.value(.title, default: "")
        caption = c.value(.caption, default: "")
        hashtags = c.value(.hashtags, default: [String]())
        hook = c.value(.hook, default: "")
        thumbnailText = c.value(.thumbnailText, default: "")
    }

    /// Caption + hashtags ready to paste.
    var shareText: String {
        let tags = hashtags.map { $0.hasPrefix("#") ? $0 : "#" + $0 }.joined(separator: " ")
        return [title, caption, tags].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct ContentPack: Codable, Hashable {
    var projectID: UUID
    var createdAt: Date
    var provider: AIProviderKind
    var keywords: [String]
    var posts: [PlatformPost]
}

// MARK: - Editing assistant

/// Clip / track references the assistant sees ("c1", "t2").
struct AssistantContext {
    struct ClipRef {
        var ref: String
        var clipID: UUID
        var trackRef: String
        var kind: String
        var name: String
        var start: Double
        var end: Double
        var text: String?
        var speed: Double
        /// Carries a picture (video / image) — target of color changes.
        var isPicture: Bool
        /// On the main (first) video track — target of "between all clips" transitions.
        var onMainTrack: Bool
    }

    struct TrackRef {
        var ref: String
        var trackID: UUID
        var kind: TrackKind
        var name: String
    }

    var clips: [ClipRef]
    var tracks: [TrackRef]
    var duration: Double
    var playhead: Double
    var selectedRefs: [String]
    var styleNames: [String]
    var frameRate: Double
    /// Part 6: the transition the user applies most (assistant memory), used when a request names none.
    var preferredTransition: TransitionKind? = nil

    func clip(_ ref: String) -> ClipRef? { clips.first { $0.ref.lowercased() == ref.lowercased() } }
    func track(_ ref: String) -> TrackRef? { tracks.first { $0.ref.lowercased() == ref.lowercased() } }
}

enum TitlePlacement: String, Codable, CaseIterable, Hashable {
    case top, center, bottom
}

enum AssistantTool: String, Codable, CaseIterable, Hashable {
    case captions, music, quality, outputs, smartTools, editingStyle, export
}

/// One validated editing operation.
enum AIEditOperation: Hashable, Codable {
    case split(time: Double)
    case trim(clip: UUID, start: Double?, end: Double?)
    case delete(clips: [UUID], ripple: Bool)
    case move(clip: UUID, to: Double)
    case speed(clip: UUID, rate: Double)
    case addTitle(text: String, start: Double, duration: Double, placement: TitlePlacement)
    case transition(clips: [UUID], kind: TransitionKind, duration: Double)
    case volume(clips: [UUID], level: Double)
    case color(clips: [UUID], exposure: Double, contrast: Double, saturation: Double, temperature: Double)
    case marker(time: Double, name: String)
    case style(id: UUID)
    case removeSilences(minimum: Double)
    case normalizeAudio
    case duckMusic
    case stabilize(clip: UUID)
    case cutToBeat(beats: Int)
    case openTool(AssistantTool)

    /// Operations that need analysis or a screen run after the timeline edit.
    var isDeferred: Bool {
        switch self {
        case .removeSilences, .normalizeAudio, .duckMusic, .stabilize, .cutToBeat, .openTool: true
        default: false
        }
    }
}

struct AIPlanStep: Identifiable, Hashable, Codable {
    var id = UUID()
    var operation: AIEditOperation
    var summary: String
    var isEnabled = true
    var isDestructive: Bool {
        switch operation {
        case .delete, .trim, .removeSilences: true
        default: false
        }
    }
}

struct AIPlan: Hashable, Codable {
    var explanation: String
    var steps: [AIPlanStep]
    var warnings: [String]
}

// MARK: - Transcript clean-up

enum CleanupKind: String, Codable, CaseIterable, Hashable {
    case filler, repetition, mistake, offTopic, pause

    var title: String {
        switch self {
        case .filler: "حشو"
        case .repetition: "تكرار"
        case .mistake: "خطأ/تلعثم"
        case .offTopic: "خارج الموضوع"
        case .pause: "وقفة"
        }
    }
}

struct TranscriptSuggestion: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Word indices (inclusive).
    var startWord: Int
    var endWord: Int
    var kind: CleanupKind
    var reason: String

    enum CodingKeys: String, CodingKey { case startWord, endWord, kind, reason }
}

extension TranscriptSuggestion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        startWord = c.value(.startWord, default: 0)
        endWord = c.value(.endWord, default: 0)
        kind = (try? c.decode(CleanupKind.self, forKey: .kind)) ?? .filler
        reason = c.value(.reason, default: "")
    }
}

struct TranscriptCleanupResult: Codable, Hashable {
    var suggestions: [TranscriptSuggestion]
}

// MARK: - Style enrichment

struct StyleEnrichment: Codable, Hashable {
    var mood: String
    var description: String
    var transitionKind: String?
    var transitionRate: Double?
    var captionPreset: String?
    var exposure: Double?
    var contrast: Double?
    var saturation: Double?
    var temperature: Double?
    var vibrance: Double?
}
