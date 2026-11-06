//
//  MediaInspector.swift
//  ClipStudio — Engines/Media
//
//  Reads media metadata (duration, oriented size, frame rate, codecs, bitrate)
//  and computes a cheap content fingerprint for duplicate detection.
//

import Foundation
import AVFoundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

struct MediaInfo {
    var kind: MediaKind
    var durationSeconds: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var frameRate: Double?
    var videoCodec: String?
    var audioCodec: String?
    var hasAudio: Bool
    var estimatedBitrate: Double?
}

enum MediaInspectorError: LocalizedError {
    case unsupported(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): "نوع الملف غير مدعوم: \(name)"
        case .unreadable(let name): "تعذّرت قراءة الملف: \(name)"
        }
    }
}

enum MediaInspector {
    static func kind(for url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    static func inspect(url: URL, kindHint: MediaKind?) async throws -> MediaInfo {
        let kind = kindHint ?? kind(for: url)
        guard let kind else { throw MediaInspectorError.unsupported(url.lastPathComponent) }
        switch kind {
        case .image: return try inspectImage(url)
        case .video, .audio: return try await inspectAV(url, kind: kind)
        }
    }

    private static func inspectImage(_ url: URL) throws -> MediaInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw MediaInspectorError.unreadable(url.lastPathComponent)
        }
        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let orientation = props[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            swap(&width, &height)
        }
        return MediaInfo(kind: .image, durationSeconds: nil, pixelWidth: width, pixelHeight: height,
                         frameRate: nil, videoCodec: nil, audioCodec: nil, hasAudio: false, estimatedBitrate: nil)
    }

    private static func inspectAV(_ url: URL, kind: MediaKind) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw MediaInspectorError.unreadable(url.lastPathComponent)
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var info = MediaInfo(kind: videoTracks.isEmpty ? .audio : kind, durationSeconds: duration.seconds.isFinite ? duration.seconds : nil,
                             pixelWidth: nil, pixelHeight: nil, frameRate: nil, videoCodec: nil, audioCodec: nil,
                             hasAudio: !audioTracks.isEmpty, estimatedBitrate: nil)
        if videoTracks.isEmpty && audioTracks.isEmpty {
            throw MediaInspectorError.unsupported(url.lastPathComponent)
        }

        var bitrate: Double = 0
        if let video = videoTracks.first {
            let (size, transform, fps, rate, formats) = try await video.load(.naturalSize, .preferredTransform,
                                                                             .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
            let oriented = size.applying(transform)
            info.pixelWidth = Int(abs(oriented.width).rounded())
            info.pixelHeight = Int(abs(oriented.height).rounded())
            info.frameRate = fps > 0 ? Double(fps) : nil
            info.videoCodec = formats.first.map { codecName($0) }
            bitrate += Double(rate)
        }
        if let audio = audioTracks.first {
            let (rate, formats) = try await audio.load(.estimatedDataRate, .formatDescriptions)
            info.audioCodec = formats.first.map { codecName($0) }
            bitrate += Double(rate)
        }
        info.estimatedBitrate = bitrate > 0 ? bitrate : nil
        return info
    }

    static func codecName(_ description: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(description)
        switch code {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "HEVC"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy: return "ProRes"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "ALAC"
        default:
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> UInt32($0)) & 0xFF))) }
            return String(chars).trimmingCharacters(in: .whitespaces)
        }
    }
}

enum MediaFingerprint {
    /// size + SHA-256 of the first and last MB. Fast even for multi-GB files.
    static func compute(_ url: URL) throws -> String {
        let size = StorageManager.shared.fileSize(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let window = 1_048_576
        if let head = try handle.read(upToCount: window) { hasher.update(data: head) }
        if size > Int64(window * 2) {
            try handle.seek(toOffset: UInt64(size - Int64(window)))
            if let tail = try handle.read(upToCount: window) { hasher.update(data: tail) }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(digest)"
    }
}
