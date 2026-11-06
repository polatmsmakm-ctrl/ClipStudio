//
//  CompositionBuilder.swift
//  ClipStudio — Engines/Rendering (EditingEngine / TimelineEngine → AVFoundation)
//
//  Converts a Timeline into:
//    • AVMutableComposition — media tracks allocated greedily so overlapping clips
//      (transitions, PiP, unlimited tracks) each get their own composition track,
//      plus a base "blank" track that guarantees frames for the whole duration;
//    • AVMutableVideoComposition — custom GPU compositor + per-interval instructions;
//    • AVMutableAudioMix — clip/track volume, keyframes and fades.
//  Speed changes use scaleTimeRange (ramps are approximated by constant-speed steps).
//  Part 2: BuiltComposition keeps the resolved visual layers so Pro Studio can
//  refresh attribute-only edits (transform, color, effects…) instantly.
//  Part 3: track solo, Audio Studio processing taps (EQ, noise reduction, dynamics,
//  gain above 100 %, balance, level meters) and the project watermark.
//  Part 4: preloads stabilization paths and horizon angles.
//

import Foundation
import AVFoundation
import CoreImage
import ImageIO

enum CompositionError: LocalizedError {
    case emptyTimeline
    case trackCreationFailed
    case missingMedia([String])

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: "الخط الزمني فارغ — لا يوجد شيء لعرضه."
        case .trackCreationFailed: "تعذّر إنشاء مسار في التركيب."
        case .missingMedia(let names): "ملفات مفقودة: " + names.joined(separator: "، ")
        }
    }
}

struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let videoTracks: [AVMutableCompositionTrack]
    let audioTracks: [AVMutableCompositionTrack]
    let duration: CMTime
    let renderSize: CGSize
    let warnings: [String]
    /// Visual layers as resolved for this build (enables attribute-only refreshes).
    let visualTracks: [TrackLayer]
    let baseTrackID: CMPersistentTrackID
    /// Live audio effect parameters read by the processing taps (update to hear changes).
    let audioParameters: AudioParameterStore
    /// Output levels per timeline track (mixer meters).
    let audioMeters: AudioMeterStore
    let watermark: ResolvedWatermark?

    func makePlayerItem() -> AVPlayerItem {
        let asset = (composition.copy() as? AVComposition) ?? composition
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }

    /// A new video composition that renders the clips' current visual attributes
    /// (transform, color, effects, masks, text content…) without rebuilding media
    /// tracks. Valid only when clip ids, timing and media sources are unchanged —
    /// returns nil when a clip can no longer be found (caller must rebuild).
    /// `excluding` hides clips (used to grab "before" frames for adjustment layers).
    func refreshedVideoComposition(with timeline: Timeline, background: RGBAColor,
                                   excluding: Set<UUID> = []) -> AVMutableVideoComposition? {
        var lookup: [UUID: Clip] = [:]
        for track in timeline.tracks {
            for clip in track.clips { lookup[clip.id] = clip }
        }
        var tracks: [TrackLayer] = []
        for layer in visualTracks {
            var entries: [LayerEntry] = []
            for entry in layer.entries {
                if excluding.contains(entry.clip.id) { continue }
                guard let clip = lookup[entry.clip.id] else { return nil }
                let source: ResolvedSource
                switch (entry.source, clip.source) {
                case (.generated, .text(let content)): source = .generated(.text(content))
                case (.generated, .shape(let content)): source = .generated(.shape(content))
                case (.generated, .sticker(let content)): source = .generated(.sticker(content))
                case (.solid, .solidColor(let color)): source = .solid(color)
                default: source = entry.source
                }
                entries.append(LayerEntry(clip: clip, source: source, start: entry.start, duration: entry.duration))
            }
            if !entries.isEmpty { tracks.append(TrackLayer(kind: layer.kind, entries: entries)) }
        }
        guard let copy = videoComposition.mutableCopy() as? AVMutableVideoComposition else { return nil }
        copy.customVideoCompositorClass = ClipCompositor.self
        copy.instructions = CompositionBuilder.makeInstructions(visualTracks: tracks, duration: duration,
                                                                baseTrackID: baseTrackID, background: background,
                                                                watermark: watermark)
        return copy
    }
}

private struct AudioPlacement {
    let track: AVMutableCompositionTrack
    let clip: Clip
    let trackVolume: Double
    let trackID: UUID
    let trackPan: Double
    let start: CMTime
    let duration: CMTime
}

private final class TrackAllocator {
    let composition: AVMutableComposition
    let mediaType: AVMediaType
    private(set) var tracks: [AVMutableCompositionTrack] = []
    private var ends: [CMTime] = []

    init(composition: AVMutableComposition, mediaType: AVMediaType) {
        self.composition = composition
        self.mediaType = mediaType
    }

    /// A track whose content ends at or before `start` (or a new one).
    func slot(startingAt start: CMTime) throws -> Int {
        if let index = ends.firstIndex(where: { CMTimeCompare($0, start) <= 0 }) { return index }
        guard let track = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.trackCreationFailed
        }
        tracks.append(track)
        ends.append(.zero)
        return tracks.count - 1
    }

    func end(of index: Int) -> CMTime { ends[index] }
    func setEnd(_ end: CMTime, for index: Int) { ends[index] = end }
}

struct CompositionBuilder {
    let media: MediaURLMap
    /// Which composition audio tracks get an Audio Studio processing tap.
    var audioTapPolicy: AudioTapPolicy = .whenNeeded

    /// Preview render size: canvas scaled so its short side is ≤ `maxShortSide`.
    static func previewSize(canvas: CGSize, maxShortSide: CGFloat) -> CGSize {
        let short = min(canvas.width, canvas.height)
        guard short > maxShortSide, short > 0 else { return canvas }
        let scale = maxShortSide / short
        return CGSize(width: (canvas.width * scale / 2).rounded() * 2, height: (canvas.height * scale / 2).rounded() * 2)
    }

    func build(timeline: Timeline, settings: ProjectSettings, renderSize: CGSize, frameRate: Int) async throws -> BuiltComposition {
        let duration = timeline.duration.cm
        guard duration.seconds > 0.01 else { throw CompositionError.emptyTimeline }

        let composition = AVMutableComposition()
        var warnings: [String] = []
        var missing: [String] = []

        // Base track: a scaled blank video so the compositor gets frames for the whole timeline.
        let blankURL = try await BlankVideoProvider.shared.url()
        let blankAsset = AVURLAsset(url: blankURL)
        guard let blankTrack = try await blankAsset.loadTracks(withMediaType: .video).first,
              let baseTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.trackCreationFailed
        }
        let blankRange = try await blankTrack.load(.timeRange)
        try baseTrack.insertTimeRange(blankRange, of: blankTrack, at: .zero)
        baseTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: blankRange.duration), toDuration: duration)

        let videoAllocator = TrackAllocator(composition: composition, mediaType: .video)
        let audioAllocator = TrackAllocator(composition: composition, mediaType: .audio)
        var assetCache: [UUID: AVURLAsset] = [:]
        var visualTracks: [TrackLayer] = []
        var placements: [AudioPlacement] = []
        let maxStillDimension = max(renderSize.width, renderSize.height) * 1.5
        let soloActive = timeline.tracks.contains { $0.isSolo && $0.carriesAudio }
        // Stabilized clips need their camera paths in memory before rendering (Part 4).
        StabilizationStore.shared.preload(Set(timeline.tracks.flatMap { $0.clips.compactMap { $0.stabilization?.assetID } }))
        HorizonStore.shared.preload(Set(timeline.tracks.flatMap { $0.clips.compactMap { $0.horizon?.assetID } }))

        for track in timeline.tracks {
            var entries: [LayerEntry] = []
            let wantsVideo = track.kind.isVisual && !track.isHidden
            let wantsAudio = !track.isMuted && track.carriesAudio && (!soloActive || track.isSolo)

            for clip in track.clips.sorted(by: { $0.start < $1.start }) where clip.isEnabled {
                let start = clip.start.cm
                let clipDuration = clip.duration.cm
                guard clipDuration.seconds > 0.001 else { continue }

                switch clip.source {
                case .media(let assetID):
                    let useReversed = clip.speed.isReversed && clip.speed.reversedAssetID != nil
                    let effectiveID = useReversed ? (clip.speed.reversedAssetID ?? assetID) : assetID
                    guard let url = media[effectiveID] else {
                        missing.append(clip.name)
                        continue
                    }
                    let asset = assetCache[effectiveID] ?? AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    assetCache[effectiveID] = asset
                    var sourceRange = clip.sourceRange?.cm ?? CMTimeRange(start: .zero, duration: clipDuration)
                    if useReversed {
                        let assetDuration = try await asset.load(.duration)
                        sourceRange = CMTimeRange(start: CMTimeSubtract(assetDuration, CMTimeRangeGetEnd(sourceRange)),
                                                  duration: sourceRange.duration)
                    }
                    let segments = clip.speed.segments(for: sourceRange)

                    if wantsVideo, let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                        let slot = try videoAllocator.slot(startingAt: start)
                        let compTrack = videoAllocator.tracks[slot]
                        let end = try await insert(segments, of: videoTrack, into: compTrack, at: start,
                                                   currentEnd: videoAllocator.end(of: slot))
                        videoAllocator.setEnd(end, for: slot)
                        let transform = try await videoTrack.load(.preferredTransform)
                        entries.append(LayerEntry(clip: clip, source: .track(compTrack.trackID, Self.orientation(transform)),
                                                  start: start, duration: clipDuration))
                    }
                    if wantsAudio, !clip.audio.isMuted, let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                        let slot = try audioAllocator.slot(startingAt: start)
                        let compTrack = audioAllocator.tracks[slot]
                        let end = try await insert(segments, of: audioTrack, into: compTrack, at: start,
                                                   currentEnd: audioAllocator.end(of: slot))
                        audioAllocator.setEnd(end, for: slot)
                        placements.append(AudioPlacement(track: compTrack, clip: clip, trackVolume: track.volume,
                                                         trackID: track.id, trackPan: track.pan,
                                                         start: start, duration: CMTimeSubtract(end, start)))
                    }

                case .image(let assetID):
                    guard wantsVideo else { continue }
                    guard let url = media[assetID] else { missing.append(clip.name); continue }
                    guard let still = StillImageLoader.load(url: url, maxDimension: maxStillDimension) else {
                        warnings.append("تعذّرت قراءة الصورة: " + clip.name)
                        continue
                    }
                    entries.append(LayerEntry(clip: clip, source: .still(still), start: start, duration: clipDuration))

                case .freezeFrame(let assetID, let time):
                    guard wantsVideo else { continue }
                    guard let url = media[assetID] else { missing.append(clip.name); continue }
                    if let still = await StillImageLoader.frame(url: url, at: time.cm, maxDimension: maxStillDimension) {
                        entries.append(LayerEntry(clip: clip, source: .still(still), start: start, duration: clipDuration))
                    } else {
                        warnings.append("تعذّر استخراج الإطار الثابت: " + clip.name)
                    }

                case .text(let content):
                    if wantsVideo { entries.append(LayerEntry(clip: clip, source: .generated(.text(content)), start: start, duration: clipDuration)) }
                case .shape(let content):
                    if wantsVideo { entries.append(LayerEntry(clip: clip, source: .generated(.shape(content)), start: start, duration: clipDuration)) }
                case .sticker(let content):
                    if wantsVideo { entries.append(LayerEntry(clip: clip, source: .generated(.sticker(content)), start: start, duration: clipDuration)) }
                case .solidColor(let color):
                    if wantsVideo { entries.append(LayerEntry(clip: clip, source: .solid(color), start: start, duration: clipDuration)) }
                case .adjustment:
                    if wantsVideo { entries.append(LayerEntry(clip: clip, source: .adjustment, start: start, duration: clipDuration)) }
                }
            }
            if wantsVideo && !entries.isEmpty {
                visualTracks.append(TrackLayer(kind: track.kind, entries: entries))
            }
        }

        if !missing.isEmpty && visualTracks.isEmpty && placements.isEmpty {
            throw CompositionError.missingMedia(missing)
        }
        if !missing.isEmpty { warnings.append(CompositionError.missingMedia(missing).errorDescription ?? "") }

        let watermark = await WatermarkResolver.resolve(settings.activeWatermark, media: media,
                                                        maxDimension: max(renderSize.width, renderSize.height))
        let instructions = Self.makeInstructions(visualTracks: visualTracks, duration: duration,
                                                 baseTrackID: baseTrack.trackID, background: settings.backgroundColor,
                                                 watermark: watermark)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ClipCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        videoComposition.instructions = instructions
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let audioParameters = AudioParameterStore()
        let audioMeters = AudioMeterStore()
        let audioMix = Self.makeAudioMix(placements, policy: audioTapPolicy, parameters: audioParameters, meters: audioMeters)

        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                                videoTracks: [baseTrack] + videoAllocator.tracks, audioTracks: audioAllocator.tracks,
                                duration: duration, renderSize: renderSize, warnings: warnings,
                                visualTracks: visualTracks, baseTrackID: baseTrack.trackID,
                                audioParameters: audioParameters, audioMeters: audioMeters, watermark: watermark)
    }

    // MARK: Insertion

    private func insert(_ segments: [SpeedSegment], of source: AVAssetTrack, into track: AVMutableCompositionTrack,
                        at start: CMTime, currentEnd: CMTime) async throws -> CMTime {
        if CMTimeCompare(start, currentEnd) > 0 {
            track.insertEmptyTimeRange(CMTimeRange(start: currentEnd, end: start))
        }
        let available = try await source.load(.timeRange)
        var cursor = start
        for segment in segments {
            let range = CMTimeRangeGetIntersection(segment.range, otherRange: available)
            guard range.duration.seconds > 0.0005 else { continue }
            try track.insertTimeRange(range, of: source, at: cursor)
            let target = CMTimeMultiplyByFloat64(range.duration, multiplier: 1.0 / segment.rate)
            if abs(segment.rate - 1) > 0.0001 {
                track.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: target)
            }
            cursor = CMTimeAdd(cursor, target)
        }
        return cursor
    }

    static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        let degrees = Int((atan2(Double(t.b), Double(t.a)) * 180 / .pi).rounded())
        switch degrees {
        case 90: return .right
        case -90, 270: return .left
        case 180, -180: return .down
        default: return .up
        }
    }

    // MARK: Instructions

    static func makeInstructions(visualTracks: [TrackLayer], duration: CMTime, baseTrackID: CMPersistentTrackID,
                                 background: RGBAColor, watermark: ResolvedWatermark? = nil) -> [RenderInstruction] {
        var boundaries: [CMTime] = [.zero, duration]
        for track in visualTracks {
            for entry in track.entries {
                boundaries.append(CMTimeMath.max(.zero, CMTimeMath.min(entry.start, duration)))
                boundaries.append(CMTimeMath.max(.zero, CMTimeMath.min(entry.end, duration)))
            }
        }
        boundaries.sort { CMTimeCompare($0, $1) < 0 }
        var unique: [CMTime] = []
        for time in boundaries where unique.last.map({ CMTimeCompare($0, time) != 0 }) ?? true {
            unique.append(time)
        }

        var instructions: [RenderInstruction] = []
        for index in 0..<(unique.count - 1) {
            let range = CMTimeRange(start: unique[index], end: unique[index + 1])
            guard range.duration.seconds > 0 else { continue }
            let mid = CMTimeAdd(range.start, CMTimeMultiplyByRatio(range.duration, multiplier: 1, divisor: 2))
            var layers: [TrackLayer] = []
            var ids: [CMPersistentTrackID] = [baseTrackID]
            for track in visualTracks {
                let active = track.entries.filter { $0.isActive(at: mid) }
                guard !active.isEmpty else { continue }
                layers.append(TrackLayer(kind: track.kind, entries: active))
                for entry in active {
                    if case .track(let id, _) = entry.source { ids.append(id) }
                }
            }
            instructions.append(RenderInstruction(timeRange: range, sourceTrackIDs: ids, layers: layers, backgroundColor: background,
                                                  watermark: watermark))
        }
        if instructions.isEmpty {
            instructions.append(RenderInstruction(timeRange: CMTimeRange(start: .zero, duration: duration),
                                                  sourceTrackIDs: [baseTrackID], layers: [], backgroundColor: background,
                                                  watermark: watermark))
        }
        return instructions
    }

    // MARK: Audio mix

    private static func makeAudioMix(_ placements: [AudioPlacement], policy: AudioTapPolicy,
                                     parameters store: AudioParameterStore, meters: AudioMeterStore) -> AVMutableAudioMix? {
        guard !placements.isEmpty else { return nil }
        var parameters: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        var segments: [CMPersistentTrackID: [AudioTapSegment]] = [:]
        var needsTap: Set<CMPersistentTrackID> = []
        for placement in placements.sorted(by: { CMTimeCompare($0.start, $1.start) < 0 }) {
            let trackKey = placement.track.trackID
            store.set(placement.clip.id, AudioClipParameters(effects: placement.clip.audio.effects, trackPan: placement.trackPan))
            segments[trackKey, default: []].append(AudioTapSegment(start: placement.start.seconds,
                                                                   end: CMTimeAdd(placement.start, placement.duration).seconds,
                                                                   clipID: placement.clip.id, trackID: placement.trackID))
            if !placement.clip.audio.effects.isNeutral || abs(placement.trackPan) > 0.001 { needsTap.insert(trackKey) }
            let params = parameters[placement.track.trackID] ?? {
                let p = AVMutableAudioMixInputParameters(track: placement.track)
                // Pitch follows the first clip placed on this composition track.
                p.audioTimePitchAlgorithm = placement.clip.speed.preservePitch ? .spectral : .varispeed
                return p
            }()
            let points = volumePoints(placement)
            for i in 0..<(points.count - 1) {
                let a = points[i], b = points[i + 1]
                guard CMTimeCompare(b.time, a.time) > 0 else { continue }
                params.setVolumeRamp(fromStartVolume: a.volume, toEndVolume: b.volume,
                                     timeRange: CMTimeRange(start: a.time, end: b.time))
            }
            parameters[placement.track.trackID] = params
        }
        for (trackKey, params) in parameters where policy == .always || needsTap.contains(trackKey) {
            let context = AudioTapContext(segments: segments[trackKey] ?? [], parameters: store,
                                          meters: policy == .always ? meters : nil)
            params.audioTapProcessor = AudioTapFactory.makeTap(context: context)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = Array(parameters.values)
        return mix
    }

    private static func volumePoints(_ p: AudioPlacement) -> [(time: CMTime, volume: Float)] {
        let duration = p.duration.seconds
        guard duration > 0 else { return [] }
        let fadeIn = min(max(0, p.clip.audio.fadeIn), duration / 2)
        let fadeOut = min(max(0, p.clip.audio.fadeOut), duration / 2)
        var times: Set<Double> = [0, duration]
        if fadeIn > 0 { times.insert(fadeIn) }
        if fadeOut > 0 { times.insert(duration - fadeOut) }
        let keyframes = p.clip.audio.volume.keyframes
        if let first = keyframes.first, let last = keyframes.last {
            var t = max(0, first.time)
            while t < min(duration, last.time) {
                times.insert(t)
                t += 0.1
            }
            keyframes.map(\.time).filter { $0 > 0 && $0 < duration }.forEach { times.insert($0) }
        }
        return times.sorted().map { t in
            var gain = p.clip.audio.volume.value(at: t) * p.trackVolume
            if fadeIn > 0 { gain *= min(1, t / fadeIn) }
            if fadeOut > 0 { gain *= min(1, (duration - t) / fadeOut) }
            let time = CMTimeAdd(p.start, CMTime(seconds: t, preferredTimescale: 60_000))
            return (time, Float(min(max(gain, 0), 1)))
        }
    }
}

// MARK: - Stills

enum StillImageLoader {
    /// Decodes once, downsampled and orientation-corrected (EXIF) via ImageIO.
    static func load(url: URL, maxDimension: CGFloat) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxDimension),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return CIImage(cgImage: cgImage)
    }

    static func frame(url: URL, at time: CMTime, maxDimension: CGFloat) async -> CIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return CIImage(cgImage: cgImage)
    }
}

// MARK: - Blank base video

actor BlankVideoProvider {
    static let shared = BlankVideoProvider()
    private var cached: URL?

    func url() async throws -> URL {
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        let url = StorageManager.shared.renderDirectory.appendingPathComponent("blank-v1.mov")
        if FileManager.default.fileExists(atPath: url.path) {
            cached = url
            return url
        }
        try await write(to: url)
        cached = url
        return url
    }

    private func write(to url: URL) async throws {
        StorageManager.shared.ensureDirectories()
        let temp = url.deletingLastPathComponent().appendingPathComponent("blank-tmp-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let size = 64
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CompositionError.trackCreationFailed }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            } else {
                CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
            }
            guard let pixelBuffer = buffer else { throw CompositionError.trackCreationFailed }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * size)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CompositionError.trackCreationFailed }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }
}
