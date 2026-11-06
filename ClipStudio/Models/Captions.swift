//
//  Captions.swift
//  ClipStudio — Models (Dynamic captions & transcription, Part 3)
//
//  • CaptionInfo: word timing carried by a caption text clip (clip-local seconds),
//    with the highlight style used by the renderer (active word, karaoke, box…).
//  • Transcript models: per-asset word transcripts in source-media time, cached on
//    disk so a file is only transcribed once per language.
//  • CaptionStylePreset: built-in caption looks.
//

import Foundation

struct CaptionWord: Codable, Hashable {
    var text: String
    /// Clip-local seconds.
    var start: Double
    var end: Double
    /// Starts a new line inside the caption.
    var breaksLine: Bool = false

    enum CodingKeys: String, CodingKey { case text, start, end, breaksLine }
}

extension CaptionWord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: c.value(.text, default: ""), start: c.value(.start, default: 0.0), end: c.value(.end, default: 0.0),
                  breaksLine: c.value(.breaksLine, default: false))
    }
}

enum CaptionHighlight: String, Codable, CaseIterable, Hashable {
    /// Plain caption.
    case none
    /// The spoken word changes color.
    case word
    /// Spoken words fill with color as they are said.
    case karaoke
    /// A colored box moves behind the spoken word.
    case box
    /// Only the spoken word is shown (one word at a time).
    case single
    /// Words appear as they are spoken.
    case reveal

    var title: String {
        switch self {
        case .none: "بدون تمييز"
        case .word: "تلوين الكلمة"
        case .karaoke: "كاريوكي"
        case .box: "صندوق متحرك"
        case .single: "كلمة كلمة"
        case .reveal: "ظهور تدريجي"
        }
    }

    var symbol: String {
        switch self {
        case .none: "text.alignright"
        case .word: "highlighter"
        case .karaoke: "music.mic"
        case .box: "rectangle.fill.on.rectangle.fill"
        case .single: "1.square"
        case .reveal: "text.append"
        }
    }
}

struct CaptionInfo: Codable, Hashable {
    var words: [CaptionWord]
    var highlight: CaptionHighlight = .word
    var highlightColor = RGBAColor(hex: 0xE3B04B)
    var boxColor = RGBAColor(hex: 0xE3B04B)

    enum CodingKeys: String, CodingKey { case words, highlight, highlightColor, boxColor }

    /// The caption's text (words separated by spaces, line breaks kept).
    var composedText: String {
        var result = ""
        for (index, word) in words.enumerated() {
            if index > 0 { result += word.breaksLine ? "\n" : " " }
            result += word.text
        }
        return result
    }

    /// Index of the word being spoken at clip-local time `t` (the last started word
    /// stays active through short pauses).
    func activeWordIndex(at t: Double) -> Int? {
        guard !words.isEmpty else { return nil }
        if t < words[0].start { return nil }
        var active: Int?
        for (index, word) in words.enumerated() where word.start <= t + 0.0001 {
            active = index
        }
        return active
    }

    /// Replaces the words' text with `text`, keeping the timing when the word count
    /// matches and spreading the time evenly (by length) otherwise.
    mutating func retext(_ text: String, duration: Double) {
        let lines = text.components(separatedBy: .newlines)
        var tokens: [(String, Bool)] = []
        for (lineIndex, line) in lines.enumerated() {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (partIndex, part) in parts.enumerated() {
                tokens.append((part, lineIndex > 0 && partIndex == 0))
            }
        }
        guard !tokens.isEmpty else {
            words = []
            return
        }
        if tokens.count == words.count {
            for index in words.indices {
                words[index].text = tokens[index].0
                words[index].breaksLine = tokens[index].1
            }
            return
        }
        let start = words.first?.start ?? 0
        let end = max(start + 0.1, words.last?.end ?? duration)
        let totalWeight = tokens.reduce(0.0) { $0 + Double(max(1, $1.0.count)) }
        var cursor = start
        var rebuilt: [CaptionWord] = []
        for token in tokens {
            let span = (end - start) * Double(max(1, token.0.count)) / totalWeight
            rebuilt.append(CaptionWord(text: token.0, start: cursor, end: cursor + span, breaksLine: token.1))
            cursor += span
        }
        words = rebuilt
    }
}

extension CaptionInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(words: c.value(.words, default: [CaptionWord]()))
        highlight = c.value(.highlight, default: CaptionHighlight.word)
        highlightColor = c.value(.highlightColor, default: RGBAColor(hex: 0xE3B04B))
        boxColor = c.value(.boxColor, default: RGBAColor(hex: 0xE3B04B))
    }
}

// MARK: - Transcripts

struct TranscriptWord: Codable, Hashable {
    var text: String
    /// Seconds in the source media (forward time).
    var start: Double
    var end: Double
    /// 0…1 (0 when the recognizer gives none).
    var confidence: Double
}

struct TimeSpan: Codable, Hashable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }

    func contains(_ time: Double) -> Bool { time >= start && time <= end }
}

struct AssetTranscript: Codable, Hashable {
    var assetID: UUID
    var localeID: String
    var words: [TranscriptWord]
    /// Source ranges that have been transcribed.
    var covered: [TimeSpan]
    var updatedAt: Date
    /// True when part of the audio was recognized by Apple's servers (not on device).
    var usedServer: Bool

    init(assetID: UUID, localeID: String) {
        self.assetID = assetID
        self.localeID = localeID
        self.words = []
        self.covered = []
        self.updatedAt = Date()
        self.usedServer = false
    }

    /// Parts of `span` that are not transcribed yet.
    func missing(in span: TimeSpan, tolerance: Double = 0.25) -> [TimeSpan] {
        var gaps = [span]
        for part in covered.sorted(by: { $0.start < $1.start }) {
            var next: [TimeSpan] = []
            for gap in gaps {
                if part.end <= gap.start || part.start >= gap.end {
                    next.append(gap)
                    continue
                }
                if part.start > gap.start { next.append(TimeSpan(start: gap.start, end: part.start)) }
                if part.end < gap.end { next.append(TimeSpan(start: part.end, end: gap.end)) }
            }
            gaps = next
        }
        return gaps.filter { $0.duration > tolerance }
    }

    /// Adds words for a newly transcribed span (replacing any old words inside it).
    mutating func merge(_ newWords: [TranscriptWord], span: TimeSpan, server: Bool) {
        words.removeAll { $0.start >= span.start - 0.001 && $0.start < span.end }
        words.append(contentsOf: newWords)
        words.sort { $0.start < $1.start }
        covered.append(span)
        covered.sort { $0.start < $1.start }
        var merged: [TimeSpan] = []
        for part in covered {
            if let last = merged.last, part.start <= last.end + 0.05 {
                merged[merged.count - 1].end = max(last.end, part.end)
            } else {
                merged.append(part)
            }
        }
        covered = merged
        usedServer = usedServer || server
        updatedAt = Date()
    }
}

/// A word placed on the timeline (seconds).
struct TimelineWord: Hashable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Double
    /// Clip the word was spoken in.
    var clipID: UUID
}

// MARK: - Caption styles

struct CaptionStylePreset: Identifiable, Hashable {
    let id: String
    let title: String
    var style: TextStyle
    var highlight: CaptionHighlight
    var highlightColor: RGBAColor
    var boxColor: RGBAColor
    var animationIn: TextAnimation
    /// Vertical position of the caption center (0 = top, 1 = bottom).
    var positionY: Double

    static let all: [CaptionStylePreset] = [classic, bold, karaoke, box, single, reveal, minimal, neon]

    static func preset(_ id: String) -> CaptionStylePreset {
        all.first { $0.id == id } ?? classic
    }

    static let classic: CaptionStylePreset = {
        var style = TextStyle()
        style.weight = .semibold
        style.sizeRatio = 0.045
        style.backgroundColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.62)
        style.backgroundPadding = 0.3
        style.cornerRadius = 0.22
        style.shadowColor = nil
        style.maxWidthRatio = 0.84
        return CaptionStylePreset(id: "classic", title: "كلاسيكي", style: style, highlight: .none,
                                  highlightColor: RGBAColor(hex: 0xE3B04B), boxColor: RGBAColor(hex: 0xE3B04B),
                                  animationIn: .none, positionY: 0.84)
    }()

    static let bold: CaptionStylePreset = {
        var style = TextStyle()
        style.weight = .heavy
        style.sizeRatio = 0.058
        style.outlineColor = .black
        style.outlineWidth = 9
        style.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.6)
        style.shadowRadius = 8
        style.maxWidthRatio = 0.8
        return CaptionStylePreset(id: "bold", title: "بارز", style: style, highlight: .word,
                                  highlightColor: RGBAColor(hex: 0xFFD23F), boxColor: RGBAColor(hex: 0xFFD23F),
                                  animationIn: .pop, positionY: 0.72)
    }()

    static let karaoke: CaptionStylePreset = {
        var style = TextStyle()
        style.weight = .bold
        style.sizeRatio = 0.052
        style.color = RGBAColor(r: 1, g: 1, b: 1, a: 0.85)
        style.outlineColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.9)
        style.outlineWidth = 6
        style.maxWidthRatio = 0.82
        return CaptionStylePreset(id: "karaoke", title: "كاريوكي", style: style, highlight: .karaoke,
                                  highlightColor: RGBAColor(hex: 0x5FC48F), boxColor: RGBAColor(hex: 0x5FC48F),
                                  animationIn: .fade, positionY: 0.78)
    }()

    static let box: CaptionStylePreset = {
        var style = TextStyle()
        style.weight = .heavy
        style.sizeRatio = 0.054
        style.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.5)
        style.shadowRadius = 6
        style.maxWidthRatio = 0.8
        return CaptionStylePreset(id: "box", title: "صندوق", style: style, highlight: .box,
                                  highlightColor: RGBAColor(hex: 0x111111), boxColor: RGBAColor(hex: 0xE3B04B),
                                  animationIn: .pop, positionY: 0.7)
    }()

    static let single: CaptionStylePreset = {
        var style = TextStyle()
        style.weight = .heavy
        style.sizeRatio = 0.085
        style.outlineColor = .black
        style.outlineWidth = 10
        style.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.55)
        return CaptionStylePreset(id: "single", title: "كلمة كلمة", style: style, highlight: .single,
                                  highlightColor: RGBAColor(hex: 0xFFFFFF), boxColor: RGBAColor(hex: 0xE3B04B),
                                  animationIn: .none, positionY: 0.6)
    }()

    static let reveal: CaptionStylePreset = {
        var style = TextStyle()
        style.weight = .bold
        style.sizeRatio = 0.05
        style.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.7)
        style.shadowRadius = 10
        style.maxWidthRatio = 0.82
        return CaptionStylePreset(id: "reveal", title: "ظهور تدريجي", style: style, highlight: .reveal,
                                  highlightColor: RGBAColor(hex: 0xFFFFFF), boxColor: RGBAColor(hex: 0xE3B04B),
                                  animationIn: .none, positionY: 0.8)
    }()

    static let minimal: CaptionStylePreset = {
        var style = TextStyle()
        style.weight = .medium
        style.sizeRatio = 0.04
        style.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.8)
        style.shadowRadius = 5
        style.maxWidthRatio = 0.86
        return CaptionStylePreset(id: "minimal", title: "بسيط", style: style, highlight: .none,
                                  highlightColor: RGBAColor(hex: 0xE3B04B), boxColor: RGBAColor(hex: 0xE3B04B),
                                  animationIn: .fade, positionY: 0.88)
    }()

    static let neon: CaptionStylePreset = {
        var style = TextStyle()
        style.weight = .heavy
        style.sizeRatio = 0.055
        style.color = RGBAColor(hex: 0xF2EFEA)
        style.shadowColor = RGBAColor(hex: 0x39D0FF)
        style.shadowRadius = 22
        style.shadowOffsetY = 0
        style.maxWidthRatio = 0.8
        return CaptionStylePreset(id: "neon", title: "نيون", style: style, highlight: .word,
                                  highlightColor: RGBAColor(hex: 0x39D0FF), boxColor: RGBAColor(hex: 0x39D0FF),
                                  animationIn: .blur, positionY: 0.75)
    }()
}
