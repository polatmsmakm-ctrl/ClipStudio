//
//  ExportEngine.swift
//  ClipStudio — Engines/Export (ExportEngine module)
//
//  Two export paths:
//  • Render: AVAssetReader (custom compositor + audio mix) → AVAssetWriter with
//    hardware H.264/HEVC encoding, explicit bitrate, frame rate and size.
//    Pausable and cancellable; progress = last written video timestamp (real).
//  • Passthrough: AVAssetExportSession stream copy (no re-encoding).
//

import Foundation
import AVFoundation
import CoreGraphics

struct ExportOutcome {
    let url: URL
    let durationSeconds: Double
    let fileSize: Int64
    let width: Int
    let height: Int
    let codec: String
}

enum ExportError: LocalizedError {
    case unsupportedSettings
    case readerFailed(String)
    case writerFailed(String)
    case sessionUnavailable
    case missingMedia
    case notEnoughSpace

    var errorDescription: String? {
        switch self {
        case .unsupportedSettings: "إعدادات التصدير غير مدعومة على هذا الجهاز (جرّب H.264 أو دقة أقل)."
        case .readerFailed(let m): "فشلت قراءة الوسائط: " + m
        case .writerFailed(let m): "فشل كتابة الملف: " + m
        case .sessionUnavailable: "النسخ المباشر غير متاح لهذا الملف — استخدم الوضع الدقيق."
        case .missingMedia: "ملف المصدر مفقود."
        case .notEnoughSpace: "لا توجد مساحة كافية على الجهاز للتصدير."
        }
    }
}

/// Thread-safe control flags shared between the queue (main actor) and the pump thread.
final class RenderControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var cancelHandler: (() -> Void)?

    var isPaused: Bool { lock.withLock { paused } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func setPaused(_ value: Bool) { lock.withLock { paused = value } }

    func cancel() {
        let handler: (() -> Void)? = lock.withLock {
            cancelled = true
            return cancelHandler
        }
        handler?()
    }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.withLock { cancelHandler = handler }
    }
}

enum ExportGeometry {
    static func outputSize(canvas: CGSize, resolution: ResolutionPreset) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return CGSize(width: 1920, height: 1080) }
        let short = min(canvas.width, canvas.height)
        let target = resolution.shortSide ?? short
        let scale = target / short
        return CGSize(width: even(canvas.width * scale), height: even(canvas.height * scale))
    }

    static func even(_ value: CGFloat) -> CGFloat {
        CGFloat(max(2, Int((value / 2).rounded()) * 2))
    }
}

enum BitrateCalculator {
    static func videoBitrate(size: CGSize, fps: Int, settings: ExportSettings) -> Double {
        if settings.quality == .custom { return max(0.5, settings.customBitrateMbps) * 1_000_000 }
        let pixelsPerSecond = Double(size.width * size.height) * Double(max(1, fps))
        let raw = pixelsPerSecond * settings.quality.bitsPerPixel * settings.codec.efficiency
        return min(max(raw, 800_000), 150_000_000)
    }

    static func estimatedBytes(durationSeconds: Double, videoBitrate: Double, audioKbps: Int) -> Int64 {
        let bits = (videoBitrate + Double(audioKbps) * 1000) * max(0, durationSeconds)
        return Int64(bits / 8 * 1.02)
    }
}

enum ExportEngine {
    // MARK: Render (re-encode)

    static func render(payload: RenderPayload, settings: ExportSettings, media: MediaURLMap, outputURL: URL,
                       control: RenderControl, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportOutcome {
        let size = ExportGeometry.outputSize(canvas: payload.projectSettings.canvasSize, resolution: settings.resolution)
        let fps = settings.frameRate.value ?? payload.projectSettings.frameRate
        let built = try await CompositionBuilder(media: media).build(timeline: payload.timeline, settings: payload.projectSettings,
                                                                     renderSize: size, frameRate: fps)
        var range = CMTimeRange(start: .zero, duration: built.duration)
        if let requested = payload.range?.cm {
            range = CMTimeRangeGetIntersection(requested, otherRange: range)
        }
        guard range.duration.seconds > 0.01 else { throw CompositionError.emptyTimeline }

        let bitrate = BitrateCalculator.videoBitrate(size: size, fps: fps, settings: settings)
        let estimate = BitrateCalculator.estimatedBytes(durationSeconds: range.duration.seconds, videoBitrate: bitrate,
                                                        audioKbps: settings.audioBitrateKbps)
        guard StorageManager.shared.hasSpace(for: estimate) else { throw ExportError.notEnoughSpace }

        try? FileManager.default.removeItem(at: outputURL)
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = range

        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: built.videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.readerFailed("video output") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !built.audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: built.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.container.fileType)
        writer.shouldOptimizeForNetworkUse = true

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoAllowFrameReorderingKey: true
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec.avType,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw ExportError.unsupportedSettings }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.unsupportedSettings }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: settings.audioBitrateKbps * 1000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let pump = TranscodePump(reader: reader, writer: writer, videoOutput: videoOutput, videoInput: videoInput,
                                 audioOutput: audioInput == nil ? nil : audioOutput, audioInput: audioInput,
                                 range: range, control: control, progress: progress)
        try await pump.run()

        return ExportOutcome(url: outputURL, durationSeconds: range.duration.seconds,
                             fileSize: StorageManager.shared.fileSize(outputURL),
                             width: Int(size.width), height: Int(size.height), codec: settings.codec.title)
    }

    // MARK: Passthrough (stream copy)

    static func passthrough(sourceURL: URL, range: TimeRangeValue?, container: ExportContainer, outputURL: URL,
                            control: RenderControl, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportOutcome {
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.sessionUnavailable
        }
        let duration = try await asset.load(.duration)
        var timeRange = CMTimeRange(start: .zero, duration: duration)
        if let range { timeRange = CMTimeRangeGetIntersection(range.cm, otherRange: timeRange) }

        let estimated = Int64(Double(StorageManager.shared.fileSize(sourceURL)) * (timeRange.duration.seconds / max(0.01, duration.seconds)))
        guard StorageManager.shared.hasSpace(for: estimated) else { throw ExportError.notEnoughSpace }

        let fileType: AVFileType = session.supportedFileTypes.contains(container.fileType) ? container.fileType : .mov
        var target = outputURL
        if fileType != container.fileType { target = outputURL.deletingPathExtension().appendingPathExtension("mov") }
        try? FileManager.default.removeItem(at: target)

        session.outputURL = target
        session.outputFileType = fileType
        session.timeRange = timeRange
        session.shouldOptimizeForNetworkUse = true
        control.onCancel { session.cancelExport() }

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await session.export()
        poller.cancel()

        switch session.status {
        case .completed:
            progress(1)
            var width = 0, height = 0
            if let track = try? await AVURLAsset(url: target).loadTracks(withMediaType: .video).first,
               let loaded = try? await track.load(.naturalSize, .preferredTransform) {
                let oriented = loaded.0.applying(loaded.1)
                width = Int(abs(oriented.width))
                height = Int(abs(oriented.height))
            }
            return ExportOutcome(url: target, durationSeconds: timeRange.duration.seconds,
                                 fileSize: StorageManager.shared.fileSize(target), width: width, height: height,
                                 codec: "نسخ مباشر")
        case .cancelled:
            try? FileManager.default.removeItem(at: target)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: target)
            throw ExportError.writerFailed(session.error?.localizedDescription ?? "unknown")
        }
    }
}

// MARK: - Reader → writer pump

/// Runs on its own thread: interleaves video and audio appends, honours pause/cancel.
private final class TranscodePump: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOutput: AVAssetReaderOutput
    let videoInput: AVAssetWriterInput
    let audioOutput: AVAssetReaderOutput?
    let audioInput: AVAssetWriterInput?
    let range: CMTimeRange
    let control: RenderControl
    let progress: @Sendable (Double) -> Void

    init(reader: AVAssetReader, writer: AVAssetWriter, videoOutput: AVAssetReaderOutput, videoInput: AVAssetWriterInput,
         audioOutput: AVAssetReaderOutput?, audioInput: AVAssetWriterInput?, range: CMTimeRange,
         control: RenderControl, progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.range = range
        self.control = control
        self.progress = progress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let thread = Thread { [self] in
                do {
                    try self.loop()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "ClipStudio.Export"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func loop() throws {
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: range.start)

        var videoDone = false
        var audioDone = audioInput == nil
        let total = max(0.001, range.duration.seconds)
        var lastReported = -1.0

        while !(videoDone && audioDone) {
            if control.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: writer.outputURL)
                throw CancellationError()
            }
            if control.isPaused {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            var didWork = false
            autoreleasepool {
                if !videoDone && videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        if videoInput.append(sample) {
                            let seconds = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), range.start).seconds
                            let fraction = min(1, max(0, seconds / total))
                            if fraction - lastReported >= 0.005 {
                                lastReported = fraction
                                progress(fraction)
                            }
                        } else {
                            videoDone = true
                            audioDone = true
                        }
                    } else {
                        videoInput.markAsFinished()
                        videoDone = true
                    }
                    didWork = true
                }
                if !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        if !audioInput.append(sample) { audioDone = true; videoDone = true }
                    } else {
                        audioInput.markAsFinished()
                        audioDone = true
                    }
                    didWork = true
                }
            }
            if reader.status == .failed {
                writer.cancelWriting()
                throw ExportError.readerFailed(reader.error?.localizedDescription ?? "")
            }
            if writer.status == .failed {
                reader.cancelReading()
                throw ExportError.writerFailed(writer.error?.localizedDescription ?? "")
            }
            if !didWork { Thread.sleep(forTimeInterval: 0.002) }
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "")
        }
        progress(1)
    }
}
