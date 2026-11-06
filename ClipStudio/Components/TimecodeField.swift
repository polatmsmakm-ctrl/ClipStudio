//
//  TimecodeField.swift
//  ClipStudio — Components
//
//  Timecode parsing and a "go to timecode" sheet. Accepts HH:MM:SS:FF, MM:SS:FF,
//  MM:SS, plain seconds (12.5), relative jumps (+2s, -10f) and Arabic digits.
//

import SwiftUI

enum TimecodeParser {
    /// Parses user input into seconds. `current` is used for relative entries.
    static func parse(_ raw: String, fps: Double, current: Double) -> Double? {
        let digitsMap: [Character: Character] = [
            "٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4", "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9",
            "٫": ".", "،": ":", ";": ":"
        ]
        var text = String(raw.map { digitsMap[$0] ?? $0 }).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let frameRate = max(1, fps.rounded())

        var sign: Double = 0
        if text.hasPrefix("+") { sign = 1; text.removeFirst() } else if text.hasPrefix("-") { sign = -1; text.removeFirst() }

        let magnitude: Double?
        if text.hasSuffix("f"), let frames = Double(text.dropLast()) {
            magnitude = frames / frameRate
        } else if text.hasSuffix("s"), let seconds = Double(text.dropLast()) {
            magnitude = seconds
        } else if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) ?? .nan }
            guard !parts.contains(where: { $0.isNaN }) else { return nil }
            switch parts.count {
            case 2: magnitude = parts[0] * 60 + parts[1]
            case 3: magnitude = parts[0] * 60 + parts[1] + parts[2] / frameRate
            case 4: magnitude = parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / frameRate
            default: magnitude = nil
            }
        } else {
            magnitude = Double(text)
        }
        guard let magnitude, magnitude.isFinite else { return nil }
        if sign == 0 { return max(0, magnitude) }
        return max(0, current + sign * magnitude)
    }
}

struct GoToTimecodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let fps: Double
    let current: Double
    let duration: Double
    let onGo: (Double) -> Void

    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("00:00:00:00", text: $text)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.system(.title3, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .environment(\.layoutDirection, .leftToRight)
                        .focused($focused)
                        .onSubmit(go)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                } header: {
                    Text("الموضع الحالي: " + Fmt.timecode(current, fps: fps))
                } footer: {
                    Text("أمثلة: 00:01:20:12 • 1:20 • 12.5 • +2s • -10f")
                }
            }
            .screenBackground()
            .navigationTitle("انتقال إلى")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("انتقال", action: go) }
            }
            .keyboardDoneToolbar()
            .onAppear {
                text = Fmt.timecode(current, fps: fps)
                focused = true
            }
        }
        .presentationDetents([.height(300)])
    }

    private func go() {
        guard let seconds = TimecodeParser.parse(text, fps: fps, current: current) else {
            error = "صيغة غير صحيحة"
            return
        }
        onGo(min(seconds, duration))
        dismiss()
    }
}
