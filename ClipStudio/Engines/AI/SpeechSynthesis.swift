//
//  SpeechSynthesis.swift
//  ClipStudio — Engines/AI (Part 6 suggestions)
//
//  Generated voiceover from text (storyboard voice-over lines, or any text in the
//  Studio): Apple's on-device voices (AVSpeechSynthesizer written to a file — no
//  network) or a Gemini TTS voice with the user's key (text only is sent). The
//  result is an audio file that is registered in the media library and placed on
//  a voiceover track like a recorded take.
//

import Foundation
import AVFoundation

enum SpeechSynthesisError: LocalizedError {
    case emptyText
    case noAudio

    var errorDescription: String? {
        switch self {
        case .emptyText: "اكتب نص التعليق أولًا."
        case .noAudio: "لم يُنتج صوت — جرّب صوتًا آخر."
        }
    }
}

enum SpeechSynthesis {
    /// Gemini prebuilt voices offered in the picker.
    static let geminiVoices: [(id: String, title: String)] = [
        ("Kore", "Kore — واضح"), ("Puck", "Puck — مرح"), ("Charon", "Charon — هادئ"), ("Fenrir", "Fenrir — حماسي"),
        ("Aoede", "Aoede — ناعم"), ("Leda", "Leda — شبابي"), ("Orus", "Orus — رصين"), ("Zephyr", "Zephyr — مشرق")
    ]

    /// Device voice languages offered first.
    static let preferredLanguages = ["ar-SA", "ar-AE", "ar-EG", "en-US", "en-GB", "fr-FR", "es-ES", "tr-TR"]

    // MARK: Pure helpers

    /// Splits long text at sentence ends so each part stays under `maxLength` characters.
    static func chunks(_ text: String, maxLength: Int = 1200) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed.isEmpty ? [] : [trimmed] }
        var parts: [String] = []
        var current = ""
        var sentence = ""
        func push(_ piece: String) {
            if current.count + piece.count > maxLength, !current.isEmpty {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            if piece.count > maxLength {
                var rest = Substring(piece)
                while rest.count > maxLength {
                    parts.append(String(rest.prefix(maxLength)))
                    rest = rest.dropFirst(maxLength)
                }
                current = String(rest)
            } else {
                current += piece
            }
        }
        for character in trimmed {
            sentence.append(character)
            if ".!?؟\n".contains(character) {
                push(sentence)
                sentence = ""
            }
        }
        if !sentence.isEmpty { push(sentence) }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }

    /// A RIFF/WAVE file around 16-bit little-endian PCM.
    static func wav(pcm16: Data, sampleRate: Int, channels: Int) -> Data {
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteRate = UInt32(sampleRate * channels * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm16.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(byteRate)
        append16(UInt16(channels * 2))
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm16.count))
        data.append(pcm16)
        return data
    }

    /// Text sent to Gemini (optional speaking style first).
    static func geminiText(_ text: String, style: String) -> String {
        let cleanStyle = style.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanStyle.isEmpty ? text : cleanStyle + ": " + text
    }

    // MARK: Device voices

    static func deviceVoices(language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                if (lhs.language == language) != (rhs.language == language) { return lhs.language == language }
                return lhs.name < rhs.name
            }
    }

    static func voiceTitle(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = " • ممتاز"
        case .enhanced: quality = " • محسّن"
        default: quality = ""
        }
        return voice.name + " (" + voice.language + ")" + quality
    }

    // MARK: Synthesis

    /// Speaks `text` into an audio file in the staging folder.
    @MainActor
    static func synthesize(_ text: String, options: VoiceoverOptions) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechSynthesisError.emptyText }
        switch options.engine {
        case .gemini:
            let wav = try await AIRequestRouter.shared.speech(text: geminiText(trimmed, style: options.style), voice: options.geminiVoice)
            let url = StorageManager.shared.stagingURL(extension: "wav")
            try wav.write(to: url, options: .atomic)
            return url
        case .device:
            let utterance = AVSpeechUtterance(string: trimmed)
            if let id = options.deviceVoice, let voice = AVSpeechSynthesisVoice(identifier: id) {
                utterance.voice = voice
            } else {
                utterance.voice = deviceVoices(language: options.language).first ?? AVSpeechSynthesisVoice(language: options.language)
            }
            utterance.rate = Float(min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, Float(options.rate))))
            utterance.pitchMultiplier = Float(min(2, max(0.5, options.pitch)))
            utterance.preUtteranceDelay = 0
            utterance.postUtteranceDelay = 0
            let writer = DeviceSpeechWriter(url: StorageManager.shared.stagingURL(extension: "caf"))
            return try await writer.run(utterance)
        }
    }
}

/// Writes AVSpeechSynthesizer output to a file (no audio is played).
final class DeviceSpeechWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var finished = false
    private var continuation: CheckedContinuation<URL, Error>?

    init(url: URL) {
        self.url = url
        super.init()
        synthesizer.delegate = self
    }

    func run(_ utterance: AVSpeechUtterance) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                synthesizer.write(utterance) { [weak self] buffer in
                    self?.handle(buffer)
                }
            }
        } onCancel: {
            self.synthesizer.stopSpeaking(at: .immediate)
            self.finish(CancellationError())
        }
    }

    private func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            finish(nil)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat,
                                       interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
            framesWritten += AVAudioFramePosition(pcm.frameLength)
        } catch {
            lock.unlock()
            finish(error)
            lock.lock()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // The last buffers can arrive just after this callback.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.finish(nil) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(CancellationError())
    }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        file = nil
        let written = framesWritten
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error {
            try? FileManager.default.removeItem(at: url)
            continuation?.resume(throwing: error)
        } else if written == 0 {
            try? FileManager.default.removeItem(at: url)
            continuation?.resume(throwing: SpeechSynthesisError.noAudio)
        } else {
            continuation?.resume(returning: url)
        }
    }
}

extension AIModelManager {
    static let fallbackTTSModel = "gemini-2.5-flash-preview-tts"

    /// The newest Gemini TTS model in the list (flash preferred).
    nonisolated static func bestTTS(_ models: [GeminiModelInfo]) -> String? {
        models.filter { $0.id.lowercased().hasPrefix("gemini") && $0.id.lowercased().contains("tts") }
            .max { lhs, rhs in
                let l = (lhs.id.contains("flash") ? 1000.0 : 0) + version(lhs.id)
                let r = (rhs.id.contains("flash") ? 1000.0 : 0) + version(rhs.id)
                return l != r ? l < r : lhs.id > rhs.id
            }?.id
    }

    var ttsModel: String { Self.bestTTS(models) ?? Self.fallbackTTSModel }
}
