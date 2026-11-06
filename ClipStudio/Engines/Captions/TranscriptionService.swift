//
//  TranscriptionService.swift
//  ClipStudio — Engines/Captions (Part 3)
//
//  Speech-to-text with Apple's Speech framework (Arabic, English and more).
//  Audio of the needed source range is cut into chunks of ≤ 50 s (boundaries moved
//  to the quietest moment nearby so words are not split), each chunk is exported to
//  a temporary AAC file and recognized with word timestamps. On-device recognition
//  is used whenever the language supports it; otherwise — only after the user has
//  agreed in the captions screen — Apple's servers are used, and the transcript is
//  marked accordingly. Progress is real (per processed second) and cancellable.
//

import Foundation
import AVFoundation
import Speech

struct TranscriptionLanguage: Identifiable, Hashable {
    let id: String
    let title: String

    static let all: [TranscriptionLanguage] = [
        TranscriptionLanguage(id: "ar-SA", title: "العربية (السعودية)"),
        TranscriptionLanguage(id: "ar-AE", title: "العربية (الإمارات)"),
        TranscriptionLanguage(id: "ar-KW", title: "العربية (الكويت)"),
        TranscriptionLanguage(id: "ar-QA", title: "العربية (قطر)"),
        TranscriptionLanguage(id: "en-US", title: "English (US)"),
        TranscriptionLanguage(id: "en-GB", title: "English (UK)"),
        TranscriptionLanguage(id: "fr-FR", title: "Français"),
        TranscriptionLanguage(id: "es-ES", title: "Español"),
        TranscriptionLanguage(id: "de-DE", title: "Deutsch"),
        TranscriptionLanguage(id: "tr-TR", title: "Türkçe"),
        TranscriptionLanguage(id: "hi-IN", title: "हिन्दी"),
        TranscriptionLanguage(id: "id-ID", title: "Bahasa Indonesia")
    ]

    /// Languages this device's recognizer supports.
    static var available: [TranscriptionLanguage] {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier.replacingOccurrences(of: "_", with: "-") })
        let filtered = all.filter { supported.contains($0.id) }
        return filtered.isEmpty ? all : filtered
    }
}

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case unsupportedLanguage
    case recognizerUnavailable
    case serverNotAllowed
    case noAudio
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "لم يُسمح بالتعرّف على الكلام. فعّله من الإعدادات ← ClipStudio."
        case .unsupportedLanguage: "هذه اللغة غير مدعومة للتعرّف على الكلام في جهازك."
        case .recognizerUnavailable: "خدمة التعرّف على الكلام غير متاحة الآن. حاول بعد قليل."
        case .serverNotAllowed: "هذه اللغة تحتاج خوادم Apple في جهازك. فعّل خيار السماح بها إن رغبت."
        case .noAudio: "لا يوجد صوت في المقاطع المختارة."
        case .cancelled: "تم إلغاء التفريغ."
        case .failed(let message): "تعذّر التعرّف على الكلام: " + message
        }
    }
}

/// Resumes a continuation exactly once (recognition handlers may fire repeatedly).
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let shouldRun: Bool = lock.withLock {
            if done { return false }
            done = true
            return true
        }
        if shouldRun { body() }
    }
}

enum TranscriptionService {
    static let maxChunk: Double = 50

    static var authorization: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    static func requestAuthorization() async -> Bool {
        if authorization == .authorized { return true }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    static func supportsOnDevice(_ localeID: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeID))?.supportsOnDeviceRecognition ?? false
    }

    /// Chunk boundaries for `span`, nudged to the quietest point within ±4 s.
    static func chunks(for span: TimeSpan, waveform: Waveform?) -> [TimeSpan] {
        var result: [TimeSpan] = []
        var cursor = span.start
        while span.end - cursor > 0.05 {
            var end = min(span.end, cursor + maxChunk)
            if end < span.end, let waveform {
                var best = end
                var quietest = Float.greatestFiniteMagnitude
                var probe = max(cursor + maxChunk * 0.6, end - 4)
                while probe <= end {
                    let level = waveform.peak(from: probe - 0.05, to: probe + 0.05)
                    if level < quietest {
                        quietest = level
                        best = probe
                    }
                    probe += 0.05
                }
                end = best
            }
            result.append(TimeSpan(start: cursor, end: end))
            cursor = end
        }
        return result
    }

    /// Transcribes `span` (source seconds) of the media file at `url`.
    /// - Returns: words in source time and whether any audio went to Apple's servers.
    static func transcribe(url: URL, span: TimeSpan, localeID: String, allowServer: Bool, waveform: Waveform?,
                           control: RenderControl, progress: @escaping (Double) -> Void) async throws -> (words: [TranscriptWord], usedServer: Bool) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            throw TranscriptionError.unsupportedLanguage
        }
        guard recognizer.isAvailable else { throw TranscriptionError.recognizerUnavailable }
        let onDevice = recognizer.supportsOnDeviceRecognition
        if !onDevice && !allowServer { throw TranscriptionError.serverNotAllowed }

        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else { throw TranscriptionError.noAudio }
        let parts = chunks(for: span, waveform: waveform)
        let total = max(0.001, span.duration)
        var processed = 0.0
        var words: [TranscriptWord] = []

        for part in parts {
            if control.isCancelled { throw TranscriptionError.cancelled }
            let chunkURL = StorageManager.shared.stagingURL(extension: "m4a")
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            try await exportChunk(asset: asset, track: audioTrack, range: part, to: chunkURL)
            if control.isCancelled { throw TranscriptionError.cancelled }
            let segments = try await recognize(url: chunkURL, recognizer: recognizer, onDevice: onDevice, control: control)
            for segment in segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = part.start + segment.start
                let end = min(part.end, part.start + max(segment.end, segment.start + 0.05))
                words.append(TranscriptWord(text: text, start: start, end: end, confidence: segment.confidence))
            }
            processed += part.duration
            progress(min(1, processed / total))
        }
        return (words, !onDevice)
    }

    private static func exportChunk(asset: AVURLAsset, track: AVAssetTrack, range: TimeSpan, to url: URL) async throws {
        let composition = AVMutableComposition()
        guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TranscriptionError.noAudio
        }
        let timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600),
                                    end: CMTime(seconds: range.end, preferredTimescale: 600))
        try audio.insertTimeRange(timeRange, of: track, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.failed("export")
        }
        session.outputURL = url
        session.outputFileType = .m4a
        let box = ExportSessionBox(session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { continuation.resume() }
        }
        guard box.session.status == .completed else {
            throw TranscriptionError.failed(box.session.error?.localizedDescription ?? "export")
        }
    }

    private struct Segment {
        let text: String
        let start: Double
        let end: Double
        let confidence: Double
    }

    @MainActor
    private static func recognize(url: URL, recognizer: SFSpeechRecognizer, onDevice: Bool,
                                  control: RenderControl) async throws -> [Segment] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        request.taskHint = .dictation
        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let segments = result.bestTranscription.segments.map {
                        Segment(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration, confidence: Double($0.confidence))
                    }
                    gate.run { continuation.resume(returning: segments) }
                    return
                }
                if let error {
                    let code = (error as NSError).code
                    gate.run {
                        if control.isCancelled {
                            continuation.resume(throwing: TranscriptionError.cancelled)
                        } else if code == 1110 || code == 203 || code == 1107 {
                            // "No speech detected" — a silent chunk.
                            continuation.resume(returning: [])
                        } else {
                            continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                        }
                    }
                }
            }
            control.onCancel { task.cancel() }
        }
    }
}
