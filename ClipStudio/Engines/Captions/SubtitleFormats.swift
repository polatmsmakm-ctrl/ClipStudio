//
//  SubtitleFormats.swift
//  ClipStudio — Engines/Captions (Part 3)
//
//  SRT and WebVTT reading/writing. The parser is tolerant: BOM, CRLF, missing
//  index lines, "," or "." milliseconds, MM:SS.mmm timestamps, cue settings,
//  styling tags and Arabic-Indic digits are all handled.
//

import Foundation

enum SubtitleFormat: String, CaseIterable, Identifiable {
    case srt, vtt

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String { self == .srt ? "SRT" : "WebVTT" }
}

struct SubtitleCue: Hashable {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleCodec {

    // MARK: Parse

    static func parse(_ raw: String) -> [SubtitleCue] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = asciiDigits(text).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = text.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
                  let end = parseTimestamp(String(endToken)), end > start else { continue }
            let body = lines[(timingIndex + 1)...].map(stripTags).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03,456", "01:02:03.456", "02:03.456", "03.5".
    static func parseTimestamp(_ token: String) -> Double? {
        let cleaned = token.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static func stripTags(_ line: String) -> String {
        var result = line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func asciiDigits(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669: scalars.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: scalars.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    // MARK: Write

    static func encode(_ cues: [SubtitleCue], format: SubtitleFormat) -> String {
        var output = format == .vtt ? "WEBVTT\n\n" : ""
        for (index, cue) in cues.sorted(by: { $0.start < $1.start }).enumerated() {
            if format == .srt { output += String(index + 1) + "\n" }
            output += timestamp(cue.start, format: format) + " --> " + timestamp(cue.end, format: format) + "\n"
            output += cue.text + "\n\n"
        }
        return output
    }

    static func timestamp(_ seconds: Double, format: SubtitleFormat) -> String {
        let totalMS = Int((max(0, seconds) * 1000).rounded())
        let ms = totalMS % 1000
        let s = (totalMS / 1000) % 60
        let m = (totalMS / 60_000) % 60
        let h = totalMS / 3_600_000
        let separator = format == .srt ? "," : "."
        return String(format: "%02ld:%02ld:%02ld", h, m, s) + separator + String(format: "%03ld", ms)
    }
}
