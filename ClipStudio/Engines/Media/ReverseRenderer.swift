//
//  ReverseRenderer.swift
//  ClipStudio — Engines/Media (VideoProcessingEngine)
//
//  Renders a reversed copy of a video (picture AND audio) for reverse playback.
//  Works in memory-bounded chunks from the end of the file to the start:
//    • each chunk's frames are decoded (NV12), re-timed in reverse order and
//      re-encoded (H.264, or HEVC above 1080p) with the source orientation;
//    • each chunk's audio is decoded to 16-bit PCM, sample-reversed and re-encoded to AAC.
//  Progress is real (fraction of source processed). Pausable and cancellable.
//  The original media is never modified — the result is a new library asset.
//

import Foundation
import AVFoundation

enum ReverseError: LocalizedError {
    case noVideo
    case readerFailed(String)
    case writerFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideo: "هذا الملف لا يحتوي على فيديو لعكسه."
        case .readerFailed(let message): "تعذّرت قراءة الفيديو: " + message
        case .writerFailed(let message): "تعذّرت كتابة الفيديو المعكوس: " + message
        case .cancelled: "تم إلغاء العكس."
        }
    }
}

enum ReverseRenderer {
    struct SourceInfo {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let duration: Double
        let size: CGSize
        let transform: CGAffineTransform
        let frameRate: Double
        let dataRate: Double
    }

    static func render(sourceURL: URL, outputURL: URL, control: RenderControl,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ReverseError.noVideo }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let size = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominal = try await videoTrack.load(.nominalFrameRate)
        let dataRate = try await videoTrack.load(.estimatedDataRate)
        let info = SourceInfo(asset: asset, videoTrack: videoTrack, audioTrack: audioTrack,
                              duration: duration.isFinite ? duration : 0, size: size, transform: transform,
                              frameRate: Double(nominal > 0 ? nominal : 30), dataRate: Double(dataRate))
        guard info.duration > 0.05 else { throw ReverseError.noVideo }

        let estimate = Int64(max(info.dataRate, 8_000_000) * 1.3 * info.duration / 8)
        guard StorageManager.shared.hasSpace(for: estimate) else { throw ExportError.notEnoughSpace }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let thread = Thread {
                do {
                    try Job(info: info, outputURL: outputURL, control: control, progress: progress).run()
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "ClipStudio.Reverse"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    // MARK: - Job

    private final class Job {
        let info: SourceInfo
        let outputURL: URL
        let control: RenderControl
        let progress: @Sendable (Double) -> Void

        static let sampleRate: Double = 48_000
        static let channels = 2

        init(info: SourceInfo, outputURL: URL, control: RenderControl, progress: @escaping @Sendable (Double) -> Void) {
            self.info = info
            self.outputURL = outputURL
            self.control = control
            self.progress = progress
        }

        func run() throws {
            try? FileManager.default.removeItem(at: outputURL)
            let width = max(2, Int(info.size.width.rounded()))
            let height = max(2, Int(info.size.height.rounded()))
            let pixels = Double(width * height)
            let codec: AVVideoCodecType = pixels > 1920 * 1088 ? .hevc : .h264
            let bitrate = min(max(info.dataRate * 1.3, pixels * info.frameRate * 0.12), 120_000_000)

            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            writer.shouldOptimizeForNetworkUse = false
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: info.frameRate,
                    AVVideoMaxKeyFrameIntervalKey: max(1, Int(info.frameRate.rounded()))
                ]
            ])
            videoInput.expectsMediaDataInRealTime = false
            videoInput.transform = info.transform
            guard writer.canAdd(videoInput) else { throw ReverseError.writerFailed("video input") }
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            var audioFormat: CMAudioFormatDescription?
            if info.audioTrack != nil, let format = Self.makePCMFormat() {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: Self.channels,
                    AVEncoderBitRateKey: 192_000
                ], sourceFormatHint: format)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                    audioFormat = format
                }
            }

            guard writer.startWriting() else {
                throw ReverseError.writerFailed(writer.error?.localizedDescription ?? "start")
            }
            writer.startSession(atSourceTime: .zero)

            let total = info.duration
            let totalSamples = Int((total * Self.sampleRate).rounded())
            let frameBytes = pixels * 1.5
            let chunk = min(1.0, max(0.2, 160_000_000 / max(1, frameBytes * info.frameRate)))
            var chunkEnd = total
            var nextFramePTS = total

            while chunkEnd > 0.0005 {
                try checkControl(writer)
                let chunkStart = max(0, chunkEnd - chunk)
                let frames = try readFrames(from: chunkStart, to: chunkEnd)
                var pendingVideo: [CMSampleBuffer] = []
                for frame in frames.reversed() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(frame).seconds
                    let newPTS = max(0, total - nextFramePTS)
                    let frameDuration = max(1.0 / 240, nextFramePTS - pts)
                    nextFramePTS = pts
                    if let retimed = Self.retime(frame, pts: newPTS, duration: frameDuration) {
                        pendingVideo.append(retimed)
                    }
                }

                var pendingAudio: [CMSampleBuffer] = []
                if let audioFormat, audioInput != nil {
                    let firstSample = Int((chunkStart * Self.sampleRate).rounded(.up))
                    let endSample = chunkEnd >= total - 0.0005 ? totalSamples : Int((chunkEnd * Self.sampleRate).rounded(.up))
                    if endSample > firstSample {
                        var pcm = try readAudio(fromSample: firstSample, toSample: endSample)
                        Self.reverseFrames(&pcm, channels: Self.channels)
                        let outputStart = max(0, totalSamples - endSample)
                        pendingAudio = Self.makeAudioBuffers(pcm, startSample: outputStart, format: audioFormat)
                    }
                }

                while !pendingVideo.isEmpty || !pendingAudio.isEmpty {
                    try checkControl(writer)
                    var didWork = false
                    if let first = pendingVideo.first, videoInput.isReadyForMoreMediaData {
                        guard videoInput.append(first) else {
                            throw ReverseError.writerFailed(writer.error?.localizedDescription ?? "video append")
                        }
                        pendingVideo.removeFirst()
                        didWork = true
                    }
                    if let audioInput, let first = pendingAudio.first, audioInput.isReadyForMoreMediaData {
                        guard audioInput.append(first) else {
                            throw ReverseError.writerFailed(writer.error?.localizedDescription ?? "audio append")
                        }
                        pendingAudio.removeFirst()
                        didWork = true
                    }
                    if writer.status == .failed {
                        throw ReverseError.writerFailed(writer.error?.localizedDescription ?? "writer")
                    }
                    if !didWork { Thread.sleep(forTimeInterval: 0.002) }
                }

                chunkEnd = chunkStart
                progress(min(0.99, (total - chunkEnd) / total))
            }

            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            semaphore.wait()
            guard writer.status == .completed else {
                throw ReverseError.writerFailed(writer.error?.localizedDescription ?? "finish")
            }
            progress(1)
        }

        private func checkControl(_ writer: AVAssetWriter) throws {
            while control.isPaused && !control.isCancelled { Thread.sleep(forTimeInterval: 0.1) }
            if control.isCancelled {
                writer.cancelWriting()
                throw ReverseError.cancelled
            }
        }

        // MARK: Reading

        /// Decoded frames whose presentation time lies in [start, end), sorted by time.
        private func readFrames(from start: Double, to end: Double) throws -> [CMSampleBuffer] {
            let reader = try AVAssetReader(asset: info.asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                                           end: CMTime(seconds: end, preferredTimescale: 60_000))
            let output = AVAssetReaderTrackOutput(track: info.videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ReverseError.readerFailed("video output") }
            reader.add(output)
            guard reader.startReading() else {
                throw ReverseError.readerFailed(reader.error?.localizedDescription ?? "start")
            }
            var frames: [CMSampleBuffer] = []
            while let buffer = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetImageBuffer(buffer) != nil else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                if pts >= start - 1e-6 && pts < end - 1e-6 { frames.append(buffer) }
            }
            if reader.status == .failed {
                throw ReverseError.readerFailed(reader.error?.localizedDescription ?? "read")
            }
            return frames.sorted {
                CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), CMSampleBufferGetPresentationTimeStamp($1)) < 0
            }
        }

        /// Interleaved 16-bit stereo PCM for sample indices [first, end).
        private func readAudio(fromSample first: Int, toSample end: Int) throws -> [Int16] {
            guard let track = info.audioTrack else { return [] }
            let channels = Self.channels
            let rate = Self.sampleRate
            let reader = try AVAssetReader(asset: info.asset)
            let padding = 0.05
            reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, Double(first) / rate - padding), preferredTimescale: 60_000),
                                           end: CMTime(seconds: Double(end) / rate + padding, preferredTimescale: 60_000))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ReverseError.readerFailed("audio output") }
            reader.add(output)
            guard reader.startReading() else {
                throw ReverseError.readerFailed(reader.error?.localizedDescription ?? "audio start")
            }
            let frameCount = end - first
            var result = [Int16](repeating: 0, count: frameCount * channels)
            var scratch: [Int16] = []
            while let buffer = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                let bufferFirst = Int((pts * rate).rounded())
                let frames = CMSampleBufferGetNumSamples(buffer)
                guard frames > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let overlapStart = max(bufferFirst, first)
                let overlapEnd = min(bufferFirst + frames, end)
                guard overlapEnd > overlapStart else { continue }
                let needed = frames * channels
                if scratch.count < needed { scratch = [Int16](repeating: 0, count: needed) }
                let status = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: needed * 2, destination: base)
                }
                guard status == kCMBlockBufferNoErr else { continue }
                for frame in overlapStart..<overlapEnd {
                    let source = (frame - bufferFirst) * channels
                    let destination = (frame - first) * channels
                    for channel in 0..<channels { result[destination + channel] = scratch[source + channel] }
                }
            }
            if reader.status == .failed {
                throw ReverseError.readerFailed(reader.error?.localizedDescription ?? "audio read")
            }
            return result
        }

        // MARK: Buffers

        static func retime(_ buffer: CMSampleBuffer, pts: Double, duration: Double) -> CMSampleBuffer? {
            var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 60_000),
                                            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 60_000),
                                            decodeTimeStamp: .invalid)
            var output: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                               sampleBufferOut: &output)
            return status == noErr ? output : nil
        }

        static func reverseFrames(_ pcm: inout [Int16], channels: Int) {
            let frames = pcm.count / channels
            guard frames > 1 else { return }
            var low = 0
            var high = frames - 1
            while low < high {
                for channel in 0..<channels {
                    pcm.swapAt(low * channels + channel, high * channels + channel)
                }
                low += 1
                high -= 1
            }
        }

        static func makePCMFormat() -> CMAudioFormatDescription? {
            var description = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: UInt32(channels * 2),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(channels * 2),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 16,
                mReserved: 0)
            var format: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
                                                        layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                        extensions: nil, formatDescriptionOut: &format)
            return status == noErr ? format : nil
        }

        /// Splits interleaved PCM into ≤ 8192-frame sample buffers starting at `startSample`.
        static func makeAudioBuffers(_ pcm: [Int16], startSample: Int, format: CMAudioFormatDescription) -> [CMSampleBuffer] {
            let totalFrames = pcm.count / channels
            let perBuffer = 8192
            var buffers: [CMSampleBuffer] = []
            var offset = 0
            while offset < totalFrames {
                let frames = min(perBuffer, totalFrames - offset)
                let byteCount = frames * channels * 2
                var block: CMBlockBuffer?
                guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                                                         blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                         offsetToData: 0, dataLength: byteCount,
                                                         flags: kCMBlockBufferAssureMemoryNowFlag,
                                                         blockBufferOut: &block) == kCMBlockBufferNoErr,
                      let block else { break }
                let copied = pcm.withUnsafeBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return -1 }
                    return CMBlockBufferReplaceDataBytes(with: base.advanced(by: offset * channels * 2), blockBuffer: block,
                                                         offsetIntoDestination: 0, dataLength: byteCount)
                }
                guard copied == kCMBlockBufferNoErr else { break }
                var sample: CMSampleBuffer?
                let pts = CMTime(value: CMTimeValue(startSample + offset), timescale: CMTimeScale(sampleRate))
                let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                                  formatDescription: format, sampleCount: frames,
                                                                                  presentationTimeStamp: pts,
                                                                                  packetDescriptions: nil, sampleBufferOut: &sample)
                if status == noErr, let sample { buffers.append(sample) }
                offset += frames
            }
            return buffers
        }
    }
}

// MARK: - Reversed asset registry

/// Remembers which library asset holds the reversed render of another asset, so a
/// source is reversed only once no matter how many clips use it.
@MainActor
final class ReverseLibrary {
    static let shared = ReverseLibrary()
    private var map: [UUID: UUID]
    private var url: URL { StorageManager.shared.stateDirectory.appendingPathComponent("reversed.json") }

    private init() {
        map = JSONStore.load([UUID: UUID].self, from: StorageManager.shared.stateDirectory.appendingPathComponent("reversed.json")) ?? [:]
    }

    func reversedAssetID(for assetID: UUID, library: MediaLibrary) -> UUID? {
        guard let id = map[assetID], let asset = library.asset(id), !library.isMissing(asset) else { return nil }
        return id
    }

    /// Renders (or reuses) the reversed asset for `asset`.
    func reversed(_ asset: MediaAsset, library: MediaLibrary, control: RenderControl,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        if let existing = reversedAssetID(for: asset.id, library: library), let found = library.asset(existing) {
            return found
        }
        let source = library.url(for: asset)
        let output = StorageManager.shared.stagingURL(extension: "mov")
        try await ReverseRenderer.render(sourceURL: source, outputURL: output, control: control, progress: progress)
        let generated = try await library.registerGenerated(file: output, displayName: asset.displayName + " (معكوس)", kind: .video)
        map[asset.id] = generated.id
        try? JSONStore.save(map, to: url)
        return generated
    }
}
