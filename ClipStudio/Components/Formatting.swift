//
//  Formatting.swift
//  ClipStudio — Components
//
//  All user-visible numbers use English digits (0123), as requested, even
//  though the UI is Arabic. Never interpolate numbers into SwiftUI string
//  literals directly — build Strings with these helpers.
//

import Foundation

enum Fmt {
    static let posix = Locale(identifier: "en_US_POSIX")
    /// Arabic language with Latin digits.
    static let arabicLatin = Locale(identifier: "ar@numbers=latn")

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// m:ss.cc
    static func durationPrecise(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let sign = seconds < 0 ? "-" : ""
        let v = abs(seconds)
        let minutes = Int(v) / 60
        let rest = v - Double(minutes * 60)
        return sign + String(format: "%d:%05.2f", minutes, rest)
    }

    /// HH:MM:SS:FF
    static func timecode(_ seconds: Double, fps: Double) -> String {
        let f = max(1, Int(fps.rounded()))
        let totalFrames = Int((max(0, seconds.isFinite ? seconds : 0) * Double(f)).rounded())
        let frames = totalFrames % f
        let totalSeconds = totalFrames / f
        return String(format: "%02d:%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60, frames)
    }

    static func seconds(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value) + " ث"
    }

    static func number(_ value: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func int(_ value: Int) -> String { String(value) }

    static func bytes(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        if b >= 1_073_741_824 { return String(format: "%.2f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
        return String(format: "%.0f B", b)
    }

    static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbps", bitsPerSecond / 1000)
    }

    static func resolution(_ width: Int, _ height: Int) -> String { "\(width)×\(height)" }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }

    static func fps(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.01 ? String(format: "%.0f fps", value) : String(format: "%.2f fps", value)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = arabicLatin
        f.calendar = Calendar(identifier: .gregorian)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = arabicLatin
        f.calendar = Calendar(identifier: .gregorian)
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = arabicLatin
        f.unitsStyle = .short
        return f
    }()

    static func date(_ date: Date) -> String { dateFormatter.string(from: date) }
    static func shortDate(_ date: Date) -> String { shortDateFormatter.string(from: date) }
    static func relative(_ date: Date) -> String { relativeFormatter.localizedString(for: date, relativeTo: Date()) }

    /// Accepts Arabic-Indic digits, Persian digits and Arabic decimal separators.
    static func parseNumber(_ text: String) -> Double? {
        let map: [Character: Character] = [
            "٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4", "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9",
            "۰": "0", "۱": "1", "۲": "2", "۳": "3", "۴": "4", "۵": "5", "۶": "6", "۷": "7", "۸": "8", "۹": "9",
            "٫": ".", ",": ".", "،": "."
        ]
        let normalized = String(text.map { map[$0] ?? $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    /// Parses "15, 30، 45" style lists into positive numbers.
    static func parseNumberList(_ text: String) -> [Double] {
        text.split(whereSeparator: { $0 == "," || $0 == "،" || $0 == " " || $0 == ";" || $0 == "\n" })
            .compactMap { parseNumber(String($0)) }
            .filter { $0 > 0 }
    }
}
