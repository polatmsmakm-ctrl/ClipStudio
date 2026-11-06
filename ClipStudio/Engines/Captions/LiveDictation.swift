//
//  LiveDictation.swift
//  ClipStudio — Engines/Captions (Part 6 suggestions)
//
//  Voice commands for the editing assistant: live speech-to-text from the
//  microphone (on device when the language supports it; Apple's servers only
//  when the user allowed it). Stops by itself after a pause, then restores the
//  playback audio session used by the Studio.
//

import Foundation
import AVFoundation
import Speech

enum DictationError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case unavailable
    case needsServer

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "اسمح للتطبيق باستخدام الميكروفون من الإعدادات › ClipStudio."
        case .speechDenied: "اسمح بالتعرّف على الكلام من الإعدادات › ClipStudio."
        case .unavailable: "التعرّف على الكلام غير متاح الآن لهذه اللغة."
        case .needsServer: "هذه اللغة غير مدعومة على جهازك — يلزم إرسال الصوت إلى Apple."
        }
    }
}

@MainActor
@Observable
final class LiveDictation {
    private(set) var isListening = false
    private(set) var text = ""
    /// 0…1 microphone level for the meter.
    private(set) var level: Double = 0

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var onFinish: ((String) -> Void)?

    /// Seconds of silence (no new words) before stopping by itself.
    var autoStopAfter: Double = 1.8

    static func supportsOnDevice(_ localeID: String) -> Bool {
        TranscriptionService.supportsOnDevice(localeID)
    }

    /// Starts listening. `onFinish` receives the final text.
    func start(localeID: String, allowServer: Bool, onFinish: @escaping (String) -> Void) async throws {
        stop(deliver: false)
        guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphoneDenied }
        guard await TranscriptionService.requestAuthorization() else { throw DictationError.speechDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            throw DictationError.unavailable
        }
        let onDevice = recognizer.supportsOnDeviceRecognition
        guard onDevice || allowServer else { throw DictationError.needsServer }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        self.request = request

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor [weak self] in self?.level = level }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.onFinish = onFinish
        text = ""
        isListening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let transcript {
                    self.text = transcript
                    self.armSilenceTimer()
                }
                if isFinal || failed { self.stop(deliver: true) }
            }
        }
        armSilenceTimer()
    }

    /// Stops listening; with `deliver` the text so far is handed to `onFinish`.
    func stop(deliver: Bool = true) {
        silenceTask?.cancel()
        silenceTask = nil
        guard isListening || engine != nil else { return }
        isListening = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        level = 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let finished = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = onFinish
        onFinish = nil
        if deliver, !finished.isEmpty { callback?(finished) }
    }

    private func armSilenceTimer() {
        silenceTask?.cancel()
        let delay = text.isEmpty ? 8 : autoStopAfter
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop(deliver: true)
        }
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += data[index] * data[index] }
        let rms = (sum / Float(count)).squareRoot()
        return Double(min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 50) / 50)))
    }
}
