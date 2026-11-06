//
//  VoiceoverRecorder.swift
//  ClipStudio — Engines/Audio (Audio Studio, Part 3)
//
//  Records a voiceover with the microphone (AAC 48 kHz mono) with a 3-2-1 count-in,
//  a live input level meter and elapsed time. The editor plays the timeline from the
//  playhead while recording (optionally muted to avoid feedback) and places the take
//  on a voiceover track at the start position.
//

import Foundation
import AVFoundation

@MainActor
@Observable
final class VoiceoverRecorder {
    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording
        case finished
    }

    private(set) var phase: Phase = .idle
    /// 0…1 smoothed input level.
    private(set) var level: Double = 0
    private(set) var elapsed: Double = 0
    private(set) var inputName = ""
    private(set) var permissionDenied = false
    private(set) var recordedURL: URL?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var onStart: (() -> Void)?

    var isActive: Bool { phase != .idle && phase != .finished }

    /// Asks for microphone permission (once).
    func requestPermission() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        permissionDenied = !granted
        return granted
    }

    /// Counts in (when `countIn`), then starts recording and calls `onStart`.
    func start(countIn: Bool, onStart: @escaping () -> Void) async {
        guard phase == .idle || phase == .finished else { return }
        guard await requestPermission() else { return }
        discardTake()
        self.onStart = onStart
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            if countIn {
                for value in stride(from: 3, through: 1, by: -1) {
                    guard let self, !Task.isCancelled else { return }
                    self.phase = .countdown(value)
                    Haptics.tap()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.beginRecording()
        }
    }

    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            inputName = session.currentRoute.inputs.first?.portName ?? ""
            StorageManager.shared.ensureDirectories()
            let url = StorageManager.shared.stagingURL(extension: "m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                phase = .idle
                restoreSession()
                return
            }
            self.recorder = recorder
            recordedURL = url
            elapsed = 0
            phase = .recording
            Haptics.success()
            onStart?()
            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMeter() }
            }
        } catch {
            phase = .idle
            restoreSession()
        }
    }

    private func updateMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let power = Double(recorder.averagePower(forChannel: 0))
        let normalized = max(0, min(1, (power + 55) / 55))
        level = level * 0.6 + normalized * 0.4
        elapsed = recorder.currentTime
    }

    /// Stops and keeps the take. Returns the file URL and its duration.
    @discardableResult
    func stop() -> (url: URL, duration: Double)? {
        countdownTask?.cancel()
        meterTimer?.invalidate()
        meterTimer = nil
        guard let recorder else {
            phase = .idle
            return nil
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        level = 0
        restoreSession()
        guard let url = recordedURL, duration > 0.2 else {
            discardTake()
            phase = .idle
            return nil
        }
        phase = .finished
        elapsed = duration
        return (url, duration)
    }

    /// Stops and deletes the current take.
    func cancel() {
        countdownTask?.cancel()
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        level = 0
        discardTake()
        restoreSession()
        phase = .idle
    }

    /// Forgets the finished take (after it was added to the project).
    func reset() {
        recordedURL = nil
        elapsed = 0
        phase = .idle
    }

    private func discardTake() {
        if let recordedURL { try? FileManager.default.removeItem(at: recordedURL) }
        recordedURL = nil
        elapsed = 0
    }

    private func restoreSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}
