//
//  CaptionBuilder.swift
//  ClipStudio — Engines/Captions (Part 3)
//
//  Turns transcripts into captions:
//  • timelineWords — maps each clip's transcript words (source time) through the
//    clip's trim and speed to timeline time;
//  • cues — groups words into readable captions (characters per line, lines,
//    maximum duration, pauses and sentence ends) with balanced line breaks;
//  • makeClip / restyle — caption text clips carrying word timing for the
//    renderer's per-word highlight.
//

import Foundation

struct CaptionCue: Hashable {
    var start: Double
    var end: Double
    /// Times relative to the cue start.
    var words: [CaptionWord]

    var text: String { CaptionInfo(words: words).composedText }
}

struct CaptionLayoutOptions: Hashable {
    var maxCharsPerLine = 32
    var maxLines = 2
    var maxDuration = 4.0
    var minDuration = 0.7
    /// A silence longer than this starts a new caption.
    var pauseBreak = 0.6

    static func defaults(for settings: ProjectSettings) -> CaptionLayoutOptions {
        var options = CaptionLayoutOptions()
        let portrait = settings.canvasHeight > settings.canvasWidth
        options.maxCharsPerLine = portrait ? 22 : 36
        options.maxLines = portrait ? 2 : 2
        return options
    }
}

enum CaptionBuilder {

    // MARK: Words on the timeline

    /// Words spoken in `clip` (from its asset transcript), in timeline seconds.
    static func timelineWords(for clip: Clip, transcript: AssetTranscript) -> [TimelineWord] {
        guard let range = clip.sourceRange, !clip.speed.isReversed else { return [] }
        let s0 = range.start.seconds, s1 = range.end.seconds
        var result: [TimelineWord] = []
        for word in transcript.words {
            let mid = (word.start + word.end) / 2
            guard mid >= s0, mid <= s1 else { continue }
            guard let localStart = SpeedMapping.localTime(of: clip, sourceTime: max(s0, word.start)),
                  let localEnd = SpeedMapping.localTime(of: clip, sourceTime: min(s1, word.end)) else { continue }
            let start = clip.start.seconds + localStart
            let end = clip.start.seconds + max(localStart + 0.04, localEnd)
            result.append(TimelineWord(text: word.text, start: start, end: end, confidence: word.confidence, clipID: clip.id))
        }
        return result
    }

    // MARK: Grouping

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "؟", "…", "۔"]
    private static let softBreaks: Set<Character> = [",", "،", ";", "؛", ":"]

    static func cues(from words: [TimelineWord], options: CaptionLayoutOptions) -> [CaptionCue] {
        let sorted = words.sorted { $0.start < $1.start }
        var groups: [[TimelineWord]] = []
        var current: [TimelineWord] = []
        for word in sorted {
            if let first = current.first, let last = current.last {
                let gap = word.start - last.end
                let candidate = current.map(\.text) + [word.text]
                let lines = lineBreaks(candidate, maxChars: options.maxCharsPerLine, maxLines: Int.max).count + 1
                let duration = word.end - first.start
                let chars = current.reduce(0) { $0 + $1.text.count + 1 }
                let endsSentence = last.text.last.map { sentenceEnders.contains($0) } ?? false
                let softEnd = (last.text.last.map { softBreaks.contains($0) } ?? false)
                    && chars >= Int(Double(options.maxCharsPerLine * options.maxLines) * 0.55)
                if gap > options.pauseBreak || duration > options.maxDuration || lines > options.maxLines || endsSentence || softEnd {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }

        var cues: [CaptionCue] = groups.map { group in
            let start = group[0].start
            let end = max(group.last?.end ?? start, start + options.minDuration)
            let breaks = Set(lineBreaks(group.map(\.text), maxChars: options.maxCharsPerLine, maxLines: options.maxLines))
            let words = group.enumerated().map { index, word in
                CaptionWord(text: word.text, start: max(0, word.start - start), end: max(0, word.end - start),
                            breaksLine: breaks.contains(index))
            }
            return CaptionCue(start: start, end: end, words: words)
        }
        // No overlaps; bridge tiny gaps so captions do not flicker.
        for index in cues.indices.dropLast() {
            let next = cues[index + 1].start
            if cues[index].end > next - 0.02 {
                cues[index].end = max(cues[index].start + 0.1, next - 0.02)
            } else if next - cues[index].end < 0.3 {
                cues[index].end = next - 0.02
            }
        }
        return cues
    }

    /// Indices of words that start a new line (balanced for two lines).
    static func lineBreaks(_ words: [String], maxChars: Int, maxLines: Int) -> [Int] {
        let total = words.reduce(0) { $0 + $1.count } + max(0, words.count - 1)
        guard total > maxChars, words.count > 1 else { return [] }
        if maxLines == 2 || total <= maxChars * 2 {
            // Best single split: both lines fit, lengths as equal as possible.
            var best: Int? = nil
            var bestScore = Int.max
            var left = 0
            for index in 1..<words.count {
                left += words[index - 1].count + (index > 1 ? 1 : 0)
                let right = total - left - 1
                guard left <= maxChars, right <= maxChars else { continue }
                let score = abs(left - right)
                if score < bestScore {
                    bestScore = score
                    best = index
                }
            }
            if let best { return [best] }
        }
        // Greedy wrapping.
        var breaks: [Int] = []
        var lineLength = 0
        for (index, word) in words.enumerated() {
            let addition = (lineLength == 0 ? 0 : 1) + word.count
            if lineLength > 0 && lineLength + addition > maxChars {
                breaks.append(index)
                lineLength = word.count
            } else {
                lineLength += addition
            }
        }
        return breaks
    }

    // MARK: Clips

    static func makeClip(_ cue: CaptionCue, preset: CaptionStylePreset) -> Clip {
        var content = TextContent(text: cue.text, style: preset.style, animationIn: preset.animationIn, animationOut: .none)
        var info = CaptionInfo(words: cue.words)
        info.highlight = preset.highlight
        info.highlightColor = preset.highlightColor
        info.boxColor = preset.boxColor
        content.caption = info
        var clip = Clip(name: shortName(cue.text), source: .text(content), start: TimeValue(seconds: cue.start),
                        duration: TimeValue(seconds: max(0.1, cue.end - cue.start)))
        clip.transform.position = KeyframedValue(Vec2(x: 0.5, y: preset.positionY))
        return clip
    }

    /// Applies a caption look (keeps the words, timing and a custom position unless asked).
    static func restyle(_ clip: inout Clip, preset: CaptionStylePreset, resetPosition: Bool) {
        guard case .text(var content) = clip.source, var info = content.caption else { return }
        content.style = preset.style
        content.animationIn = preset.animationIn
        content.animationOut = .none
        info.highlight = preset.highlight
        info.highlightColor = preset.highlightColor
        info.boxColor = preset.boxColor
        content.caption = info
        clip.source = .text(content)
        if resetPosition { clip.transform.position = KeyframedValue(Vec2(x: 0.5, y: preset.positionY)) }
    }

    /// Caption clip with evenly estimated word timing (SRT import, manual captions).
    static func estimatedClip(text: String, start: Double, end: Double, preset: CaptionStylePreset) -> Clip {
        var info = CaptionInfo(words: [CaptionWord(text: "", start: 0, end: max(0.1, end - start))])
        info.retext(text, duration: max(0.1, end - start))
        let cue = CaptionCue(start: start, end: max(start + 0.1, end), words: info.words)
        return makeClip(cue, preset: preset)
    }

    static func shortName(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 28 ? String(flat.prefix(28)) + "…" : flat
    }

    // MARK: Text cleanup

    /// Lowercased word without punctuation, tatweel or Arabic diacritics.
    static func normalized(_ word: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in word.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue
            default:
                if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) { continue }
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm", "mmm",
        "ام", "امم", "اممم", "إمم", "اه", "آه", "أه", "اا", "ااا", "آآ", "ايه", "يعني"
    ]

    static func isFiller(_ word: String) -> Bool { fillerWords.contains(normalized(word)) }
}
