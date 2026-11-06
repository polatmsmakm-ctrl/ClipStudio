//
//  Stories.swift
//  ClipStudio — Models
//
//  Smart Stories (splitting) and Smart Merge configuration models.
//

import Foundation

// MARK: - Splitting

enum SplitModeKind: String, Codable, CaseIterable, Hashable {
    /// Balanced equal parts, each ≤ the maximum duration.
    case maxDuration
    /// Every part has exactly the given duration; the remainder becomes the last part.
    case fixedDuration
    /// A fixed number of equal parts.
    case equalParts
    /// User-provided list of durations (the last value repeats until the end).
    case customDurations

    var title: String {
        switch self {
        case .maxDuration: "حد أقصى"
        case .fixedDuration: "مدة ثابتة"
        case .equalParts: "عدد أجزاء"
        case .customDurations: "مدد مخصصة"
        }
    }

    var explanation: String {
        switch self {
        case .maxDuration: "أجزاء متساوية لا يتجاوز أي منها الحد الأقصى."
        case .fixedDuration: "كل جزء بنفس المدة، والباقي يصير آخر جزء."
        case .equalParts: "قسّم الفيديو إلى عدد محدد من الأجزاء المتساوية."
        case .customDurations: "اكتب المدد بالثواني مفصولة بفواصل، وآخر مدة تتكرر."
        }
    }
}

enum SnapTarget: String, Codable, CaseIterable, Hashable {
    case none, scenes, pauses, keyframes

    var title: String {
        switch self {
        case .none: "بدون"
        case .scenes: "تغيّر المشهد"
        case .pauses: "وقفات الكلام"
        case .keyframes: "إطارات مفتاحية"
        }
    }

    var symbol: String {
        switch self {
        case .none: "minus"
        case .scenes: "film"
        case .pauses: "waveform.badge.minus"
        case .keyframes: "key"
        }
    }
}

struct SplitRule: Codable, Hashable {
    var mode: SplitModeKind = .maxDuration
    /// Used by maxDuration and fixedDuration (seconds).
    var seconds: Double = 60
    /// Used by equalParts.
    var parts: Int = 3
    /// Used by customDurations (seconds).
    var customDurations: [Double] = [15, 30]
    var snap: SnapTarget = .none
    /// Seconds a cut may move to reach a snap point.
    var snapTolerance: Double = 2
    /// Last part shorter than this is merged into the previous one when allowed.
    var minimumTail: Double = 2
    /// Hard upper limit from the selected platform preset (nil = none).
    var hardMaximum: Double? = nil
}

struct StorySegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var range: TimeRangeValue
    var name: String = ""
    var isIncluded: Bool = true
}

enum StoryExportMode: String, Codable, CaseIterable, Hashable {
    /// Stream copy with AVAssetExportPresetPassthrough (no re-encoding, source quality).
    case fastCopy
    /// Re-encode through the render engine (frame-accurate, resize/reframe, codec choice).
    case reencode

    var title: String {
        switch self {
        case .fastCopy: "سريع (بدون إعادة ترميز)"
        case .reencode: "دقيق (إعادة ترميز)"
        }
    }

    var explanation: String {
        switch self {
        case .fastCopy: "ينسخ الصوت والصورة كما هي بنفس جودة المصدر. لا يغيّر المقاس. أفضل نتيجة مع القطع عند الإطارات المفتاحية."
        case .reencode: "قطع دقيق بالإطار مع تغيير المقاس والترميز والجودة. الملف الناتج مُعاد ترميزه وليس نسخة مطابقة."
        }
    }
}

struct StoryConfig: Codable, Hashable {
    var sourceAssetID: UUID
    var presetKey: String?
    var rule = SplitRule()
    var segments: [StorySegment] = []
    var exportMode: StoryExportMode = .reencode
    var exportSettings = ExportSettings.standard
    /// nil = keep the source aspect ratio.
    var aspect: AspectRatio? = nil
    var fitMode: FitMode = .fitBlur
    /// True after the user manually moved a cut point.
    var isCustomized = false

    init(sourceAssetID: UUID) {
        self.sourceAssetID = sourceAssetID
    }

    enum CodingKeys: String, CodingKey {
        case sourceAssetID, presetKey, rule, segments, exportMode, exportSettings, aspect, fitMode, isCustomized
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceAssetID = try c.decode(UUID.self, forKey: .sourceAssetID)
        presetKey = try? c.decodeIfPresent(String.self, forKey: .presetKey)
        rule = c.value(.rule, default: SplitRule())
        segments = c.value(.segments, default: [StorySegment]())
        exportMode = c.value(.exportMode, default: StoryExportMode.reencode)
        exportSettings = c.value(.exportSettings, default: ExportSettings.standard)
        aspect = try? c.decodeIfPresent(AspectRatio.self, forKey: .aspect)
        fitMode = c.value(.fitMode, default: FitMode.fitBlur)
        isCustomized = c.value(.isCustomized, default: false)
    }
}

// MARK: - Merging

struct MergeItem: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var assetID: UUID
    /// Optional trim inside the source (videos/audio-less videos).
    var trim: TimeRangeValue? = nil
    /// Display duration for still images (seconds).
    var imageDuration: Double = 3
}

struct MusicSettings: Codable, Hashable {
    var assetID: UUID
    var volume: Double = 0.6
    var fadeIn: Double = 1
    var fadeOut: Double = 2
    var loop = true
    /// Seconds skipped at the start of the music file.
    var startOffset: Double = 0
}

struct MergeConfig: Codable, Hashable {
    var items: [MergeItem] = []
    var transition: TransitionKind = .crossDissolve
    var transitionDuration: Double = 0.6
    var music: MusicSettings? = nil
    var originalAudioVolume: Double = 1
    var muteOriginalAudio = false
    var crossfadeAudio = true
    /// nil = use the first video's aspect ratio.
    var aspect: AspectRatio? = nil
    var fitMode: FitMode = .fitBlur
    /// nil = most common source frame rate.
    var frameRate: Int? = nil
    var backgroundColor = RGBAColor.black
    var exportSettings = ExportSettings.standard

    init() {}

    enum CodingKeys: String, CodingKey {
        case items, transition, transitionDuration, music, originalAudioVolume, muteOriginalAudio
        case crossfadeAudio, aspect, fitMode, frameRate, backgroundColor, exportSettings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.value(.items, default: [MergeItem]())
        transition = c.value(.transition, default: TransitionKind.crossDissolve)
        transitionDuration = c.value(.transitionDuration, default: 0.6)
        music = try? c.decodeIfPresent(MusicSettings.self, forKey: .music)
        originalAudioVolume = c.value(.originalAudioVolume, default: 1.0)
        muteOriginalAudio = c.value(.muteOriginalAudio, default: false)
        crossfadeAudio = c.value(.crossfadeAudio, default: true)
        aspect = try? c.decodeIfPresent(AspectRatio.self, forKey: .aspect)
        fitMode = c.value(.fitMode, default: FitMode.fitBlur)
        frameRate = try? c.decodeIfPresent(Int.self, forKey: .frameRate)
        backgroundColor = c.value(.backgroundColor, default: RGBAColor.black)
        exportSettings = c.value(.exportSettings, default: ExportSettings.standard)
    }
}
