//
//  Media.swift
//  ClipStudio — Models
//
//  Media library record. The original file is copied once into the app
//  container (Application Support/ClipStudio/Media/<id>.<ext>) and never modified.
//

import Foundation

enum MediaKind: String, Codable, CaseIterable, Hashable {
    case video, audio, image

    var title: String {
        switch self {
        case .video: "فيديو"
        case .audio: "صوت"
        case .image: "صورة"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }
}

struct MediaAsset: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: MediaKind
    var displayName: String
    var originalFilename: String
    var storedFileName: String
    var importedAt: Date
    var fileSize: Int64
    var durationSeconds: Double?
    /// Display (orientation-corrected) dimensions.
    var pixelWidth: Int?
    var pixelHeight: Int?
    var frameRate: Double?
    var videoCodec: String?
    var audioCodec: String?
    var hasAudio: Bool
    var estimatedBitrate: Double?
    var fingerprint: String

    var resolutionText: String {
        guard let w = pixelWidth, let h = pixelHeight else { return "—" }
        return Fmt.resolution(w, h)
    }

    var durationText: String {
        guard let durationSeconds else { return "—" }
        return Fmt.duration(durationSeconds)
    }

    var aspect: AspectRatio? {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return nil }
        return .reduced(width: w, height: h)
    }

    var isPortrait: Bool { (pixelHeight ?? 0) > (pixelWidth ?? 0) }

    enum CodingKeys: String, CodingKey {
        case id, kind, displayName, originalFilename, storedFileName, importedAt, fileSize, durationSeconds
        case pixelWidth, pixelHeight, frameRate, videoCodec, audioCodec, hasAudio, estimatedBitrate, fingerprint
    }

    init(id: UUID, kind: MediaKind, displayName: String, originalFilename: String, storedFileName: String,
         importedAt: Date, fileSize: Int64, durationSeconds: Double?, pixelWidth: Int?, pixelHeight: Int?,
         frameRate: Double?, videoCodec: String?, audioCodec: String?, hasAudio: Bool,
         estimatedBitrate: Double?, fingerprint: String) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.originalFilename = originalFilename
        self.storedFileName = storedFileName
        self.importedAt = importedAt
        self.fileSize = fileSize
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.hasAudio = hasAudio
        self.estimatedBitrate = estimatedBitrate
        self.fingerprint = fingerprint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = c.value(.kind, default: MediaKind.video)
        displayName = c.value(.displayName, default: "وسائط")
        originalFilename = c.value(.originalFilename, default: "")
        storedFileName = try c.decode(String.self, forKey: .storedFileName)
        importedAt = c.value(.importedAt, default: Date())
        fileSize = c.value(.fileSize, default: Int64(0))
        durationSeconds = try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        pixelWidth = try? c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try? c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        frameRate = try? c.decodeIfPresent(Double.self, forKey: .frameRate)
        videoCodec = try? c.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try? c.decodeIfPresent(String.self, forKey: .audioCodec)
        hasAudio = c.value(.hasAudio, default: false)
        estimatedBitrate = try? c.decodeIfPresent(Double.self, forKey: .estimatedBitrate)
        fingerprint = c.value(.fingerprint, default: "")
    }
}
