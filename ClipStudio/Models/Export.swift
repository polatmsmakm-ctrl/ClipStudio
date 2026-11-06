//
//  Export.swift
//  ClipStudio — Models
//
//  Export settings, render payloads, persisted export jobs, export history
//  records and editable social-media platform presets.
//

import Foundation
import AVFoundation
import CoreGraphics

// MARK: - Settings

enum ExportContainer: String, Codable, CaseIterable, Hashable {
    case mp4, mov

    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
    var fileExtension: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum VideoCodec: String, Codable, CaseIterable, Hashable {
    case h264, hevc

    var avType: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
    var title: String { self == .h264 ? "H.264" : "HEVC (H.265)" }
    /// Relative bitrate needed for similar quality.
    var efficiency: Double { self == .h264 ? 1.0 : 0.62 }
}

enum ResolutionPreset: String, Codable, CaseIterable, Hashable {
    case p720, p1080, p1440, p2160, matchCanvas

    /// Target length of the shorter side (nil = keep canvas size).
    var shortSide: CGFloat? {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p1440: 1440
        case .p2160: 2160
        case .matchCanvas: nil
        }
    }

    var title: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        case .matchCanvas: "مطابقة المصدر"
        }
    }
}

enum FrameRateOption: String, Codable, CaseIterable, Hashable {
    case fps24, fps25, fps30, fps50, fps60, matchSource

    var value: Int? {
        switch self {
        case .fps24: 24
        case .fps25: 25
        case .fps30: 30
        case .fps50: 50
        case .fps60: 60
        case .matchSource: nil
        }
    }

    var title: String {
        if let value { return "\(value) fps" }
        return "مطابقة المصدر"
    }
}

enum QualityLevel: String, Codable, CaseIterable, Hashable {
    case low, medium, high, maximum, custom

    /// H.264 bits per pixel per frame.
    var bitsPerPixel: Double {
        switch self {
        case .low: 0.05
        case .medium: 0.09
        case .high: 0.14
        case .maximum: 0.24
        case .custom: 0.14
        }
    }

    var title: String {
        switch self {
        case .low: "منخفضة"
        case .medium: "متوسطة"
        case .high: "عالية"
        case .maximum: "قصوى"
        case .custom: "مخصصة"
        }
    }
}

enum ExportDestination: String, Codable, CaseIterable, Hashable {
    case files, photos, filesAndPhotos

    var title: String {
        switch self {
        case .files: "تطبيق الملفات"
        case .photos: "مكتبة الصور"
        case .filesAndPhotos: "الملفات والصور"
        }
    }

    var savesToPhotos: Bool { self != .files }
}

struct ExportSettings: Codable, Hashable {
    var container: ExportContainer = .mp4
    var codec: VideoCodec = .h264
    var resolution: ResolutionPreset = .p1080
    var frameRate: FrameRateOption = .fps30
    var quality: QualityLevel = .high
    /// Used when quality == .custom.
    var customBitrateMbps: Double = 12
    var audioBitrateKbps: Int = 192
    var destination: ExportDestination = .filesAndPhotos

    static let standard = ExportSettings()

    init() {}

    enum CodingKeys: String, CodingKey {
        case container, codec, resolution, frameRate, quality, customBitrateMbps, audioBitrateKbps, destination
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        container = c.value(.container, default: ExportContainer.mp4)
        codec = c.value(.codec, default: VideoCodec.h264)
        resolution = c.value(.resolution, default: ResolutionPreset.p1080)
        frameRate = c.value(.frameRate, default: FrameRateOption.fps30)
        quality = c.value(.quality, default: QualityLevel.high)
        customBitrateMbps = c.value(.customBitrateMbps, default: 12.0)
        audioBitrateKbps = c.value(.audioBitrateKbps, default: 192)
        destination = c.value(.destination, default: ExportDestination.filesAndPhotos)
    }
}

// MARK: - Jobs

struct RenderPayload: Codable, Hashable {
    var timeline: Timeline
    var projectSettings: ProjectSettings
    /// Optional sub-range of the timeline to export (nil = whole timeline).
    var range: TimeRangeValue?
}

enum ExportPayload: Codable, Hashable {
    case render(RenderPayload)
    case passthrough(assetID: UUID, range: TimeRangeValue?)

    var supportsPause: Bool {
        if case .render = self { return true }
        return false
    }
}

enum ExportStatus: String, Codable, Hashable {
    case queued, running, paused, completed, failed, cancelled

    var title: String {
        switch self {
        case .queued: "في الانتظار"
        case .running: "جارٍ التصدير"
        case .paused: "متوقف مؤقتاً"
        case .completed: "اكتمل"
        case .failed: "فشل"
        case .cancelled: "أُلغي"
        }
    }

    var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
}

struct ExportJob: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var batchID: UUID?
    var batchTitle: String?
    var title: String
    var outputBaseName: String
    var payload: ExportPayload
    var settings: ExportSettings
    var status: ExportStatus = .queued
    var progress: Double = 0
    var errorMessage: String?
    var note: String?
    var estimatedBytes: Int64 = 0
    var createdAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var outputFileName: String?
    var autoPaused = false
}

struct ExportRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var fileName: String
    var createdAt: Date
    var durationSeconds: Double
    var fileSize: Int64
    var width: Int
    var height: Int
    var codec: String
    var savedToPhotos: Bool
    var batchTitle: String?
}

// MARK: - Platform presets

struct PlatformPreset: Codable, Identifiable, Hashable {
    var id: UUID
    /// Stable key for built-in presets ("instagram_story"…); custom presets use their UUID string.
    var key: String
    var name: String
    var symbol: String
    /// Maximum clip duration in seconds (nil = no limit).
    var maxDuration: Double?
    /// Maximum file size in MB (nil = no limit).
    var maxFileSizeMB: Double?
    var aspect: AspectRatio
    var resolution: ResolutionPreset
    var frameRate: FrameRateOption
    var codec: VideoCodec
    var fitMode: FitMode
    var isBuiltIn: Bool
    var notes: String

    func applying(to settings: ExportSettings) -> ExportSettings {
        var result = settings
        result.resolution = resolution
        result.frameRate = frameRate
        result.codec = codec
        return result
    }

    /// Defaults are starting points only — platforms change their limits, so every
    /// value is editable in Settings › منصات التواصل.
    static let defaults: [PlatformPreset] = [
        PlatformPreset(id: UUID(uuidString: "6B1E2F3A-0001-4C5D-8E9F-000000000001")!, key: "instagram_story", name: "Instagram Stories",
                       symbol: "camera.circle", maxDuration: 60, maxFileSizeMB: nil, aspect: .portrait9x16, resolution: .p1080,
                       frameRate: .fps30, codec: .h264, fitMode: .fitBlur, isBuiltIn: true, notes: "تحقق من الحد الحالي في التطبيق."),
        PlatformPreset(id: UUID(uuidString: "6B1E2F3A-0001-4C5D-8E9F-000000000002")!, key: "instagram_reels", name: "Instagram Reels",
                       symbol: "play.rectangle.on.rectangle", maxDuration: 90, maxFileSizeMB: nil, aspect: .portrait9x16, resolution: .p1080,
                       frameRate: .fps30, codec: .h264, fitMode: .fitBlur, isBuiltIn: true, notes: "عدّل المدة حسب حدود حسابك."),
        PlatformPreset(id: UUID(uuidString: "6B1E2F3A-0001-4C5D-8E9F-000000000003")!, key: "tiktok", name: "TikTok",
                       symbol: "music.note", maxDuration: 600, maxFileSizeMB: nil, aspect: .portrait9x16, resolution: .p1080,
                       frameRate: .fps30, codec: .h264, fitMode: .fitBlur, isBuiltIn: true, notes: "الحدود تختلف حسب الحساب."),
        PlatformPreset(id: UUID(uuidString: "6B1E2F3A-0001-4C5D-8E9F-000000000004")!, key: "snapchat", name: "Snapchat",
                       symbol: "bubble.left.and.bubble.right", maxDuration: 60, maxFileSizeMB: nil, aspect: .portrait9x16, resolution: .p1080,
                       frameRate: .fps30, codec: .h264, fitMode: .fitBlur, isBuiltIn: true, notes: ""),
        PlatformPreset(id: UUID(uuidString: "6B1E2F3A-0001-4C5D-8E9F-000000000005")!, key: "whatsapp_status", name: "WhatsApp Status",
                       symbol: "phone.bubble", maxDuration: 60, maxFileSizeMB: 16, aspect: .portrait9x16, resolution: .p720,
                       frameRate: .fps30, codec: .h264, fitMode: .fitBlur, isBuiltIn: true, notes: "حد الحجم تقريبي وقابل للتعديل."),
        PlatformPreset(id: UUID(uuidString: "6B1E2F3A-0001-4C5D-8E9F-000000000006")!, key: "youtube_shorts", name: "YouTube Shorts",
                       symbol: "play.square.stack", maxDuration: 180, maxFileSizeMB: nil, aspect: .portrait9x16, resolution: .p1080,
                       frameRate: .fps30, codec: .h264, fitMode: .fitBlur, isBuiltIn: true, notes: ""),
        PlatformPreset(id: UUID(uuidString: "6B1E2F3A-0001-4C5D-8E9F-000000000007")!, key: "youtube", name: "YouTube",
                       symbol: "play.rectangle", maxDuration: nil, maxFileSizeMB: nil, aspect: .landscape16x9, resolution: .p1080,
                       frameRate: .matchSource, codec: .h264, fitMode: .fit, isBuiltIn: true, notes: ""),
        PlatformPreset(id: UUID(uuidString: "6B1E2F3A-0001-4C5D-8E9F-000000000008")!, key: "facebook", name: "Facebook",
                       symbol: "person.2", maxDuration: nil, maxFileSizeMB: nil, aspect: .portrait4x5, resolution: .p1080,
                       frameRate: .fps30, codec: .h264, fitMode: .fitBlur, isBuiltIn: true, notes: ""),
        PlatformPreset(id: UUID(uuidString: "6B1E2F3A-0001-4C5D-8E9F-000000000009")!, key: "x", name: "X",
                       symbol: "xmark.square", maxDuration: 140, maxFileSizeMB: 512, aspect: .landscape16x9, resolution: .p1080,
                       frameRate: .fps30, codec: .h264, fitMode: .fit, isBuiltIn: true, notes: "الحد يختلف للحسابات الموثّقة."),
    ]
}
