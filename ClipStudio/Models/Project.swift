//
//  Project.swift
//  ClipStudio — Models
//
//  Project document, canvas settings and aspect ratios. Each project is stored
//  as JSON in Application Support/ClipStudio/Projects/<id>/project.json with
//  automatic version snapshots (see ProjectManager).
//
//  Part 2 adds: nested sequences (compound clips) and the Pro Studio session
//  state (playhead, zoom, in/out points). Part 3 adds the project watermark
//  (schema 3). Older files decode with defaults.
//

import Foundation
import CoreGraphics

enum ProjectKind: String, Codable, CaseIterable, Hashable {
    case story, merge, pro

    var title: String {
        switch self {
        case .story: "قصة ذكية"
        case .merge: "دمج"
        case .pro: "مونتاج احترافي"
        }
    }

    var symbol: String {
        switch self {
        case .story: "scissors"
        case .merge: "rectangle.stack.badge.plus"
        case .pro: "film.stack"
        }
    }
}

struct AspectRatio: Codable, Hashable, Identifiable {
    var width: Int
    var height: Int

    var id: String { "\(width)x\(height)" }

    static let portrait9x16 = AspectRatio(width: 9, height: 16)
    static let landscape16x9 = AspectRatio(width: 16, height: 9)
    static let square = AspectRatio(width: 1, height: 1)
    static let portrait4x5 = AspectRatio(width: 4, height: 5)
    static let classic4x3 = AspectRatio(width: 4, height: 3)
    static let cinema21x9 = AspectRatio(width: 21, height: 9)

    static let common: [AspectRatio] = [.portrait9x16, .landscape16x9, .square, .portrait4x5, .classic4x3, .cinema21x9]

    var value: Double { Double(width) / Double(max(1, height)) }
    var title: String { "\(width):\(height)" }

    var label: String {
        switch (width, height) {
        case (9, 16): "عمودي 9:16"
        case (16, 9): "أفقي 16:9"
        case (1, 1): "مربع 1:1"
        case (4, 5): "بورتريه 4:5"
        case (4, 3): "كلاسيكي 4:3"
        case (21, 9): "سينمائي 21:9"
        default: title
        }
    }

    /// Even-sized canvas whose shorter side equals `shortSide`.
    func canvasSize(shortSide: Int = 1080) -> CGSize {
        let short = Double(shortSide)
        let w: Double, h: Double
        if width >= height {
            h = short
            w = short * value
        } else {
            w = short
            h = short / value
        }
        return CGSize(width: Double(Int((w / 2).rounded()) * 2), height: Double(Int((h / 2).rounded()) * 2))
    }

    static func reduced(width: Int, height: Int) -> AspectRatio {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(1, a) : gcd(b, a % b) }
        let d = gcd(abs(width), abs(height))
        return AspectRatio(width: max(1, width / d), height: max(1, height / d))
    }
}

struct ProjectSettings: Codable, Hashable {
    var canvasWidth: Int
    var canvasHeight: Int
    var frameRate: Int
    var backgroundColor: RGBAColor
    /// Project-wide watermark drawn over every frame (Part 3). nil = none.
    var watermark: WatermarkSettings?

    init(canvasWidth: Int = 1920, canvasHeight: Int = 1080, frameRate: Int = 30, backgroundColor: RGBAColor = .black) {
        self.canvasWidth = max(2, canvasWidth)
        self.canvasHeight = max(2, canvasHeight)
        self.frameRate = min(max(frameRate, 12), 120)
        self.backgroundColor = backgroundColor
        self.watermark = nil
    }

    init(aspect: AspectRatio, shortSide: Int = 1080, frameRate: Int = 30) {
        let size = aspect.canvasSize(shortSide: shortSide)
        self.init(canvasWidth: Int(size.width), canvasHeight: Int(size.height), frameRate: frameRate)
    }

    var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }
    var aspect: AspectRatio { .reduced(width: canvasWidth, height: canvasHeight) }

    /// The watermark when it is enabled and has content.
    var activeWatermark: WatermarkSettings? {
        guard let watermark, watermark.isDrawable else { return nil }
        return watermark
    }

    enum CodingKeys: String, CodingKey { case canvasWidth, canvasHeight, frameRate, backgroundColor, watermark }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(canvasWidth: c.value(.canvasWidth, default: 1920),
                  canvasHeight: c.value(.canvasHeight, default: 1080),
                  frameRate: c.value(.frameRate, default: 30),
                  backgroundColor: c.value(.backgroundColor, default: RGBAColor.black))
        watermark = try? c.decodeIfPresent(WatermarkSettings.self, forKey: .watermark)
    }
}

// MARK: - Nested sequences

/// A nested sequence ("compound clip"). Its inner timeline is rendered once to a
/// generated media asset; every timeline clip that plays `.media(renderedAssetID)`
/// is an instance of this compound and can be opened, edited and re-rendered.
struct CompoundClip: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var timeline: Timeline
    var renderedAssetID: UUID?
    var renderedAt: Date?
    /// True when the inner timeline changed after the last render.
    var needsRender: Bool

    init(id: UUID = UUID(), name: String, timeline: Timeline) {
        self.id = id
        self.name = name
        self.timeline = timeline
        self.renderedAssetID = nil
        self.renderedAt = nil
        self.needsRender = true
    }

    enum CodingKeys: String, CodingKey { case id, name, timeline, renderedAssetID, renderedAt, needsRender }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = c.value(.name, default: "تسلسل متداخل")
        timeline = c.value(.timeline, default: Timeline())
        renderedAssetID = try? c.decodeIfPresent(UUID.self, forKey: .renderedAssetID)
        renderedAt = try? c.decodeIfPresent(Date.self, forKey: .renderedAt)
        needsRender = c.value(.needsRender, default: renderedAssetID == nil)
    }
}

/// Pro Studio UI state restored when the project is reopened.
struct StudioState: Codable, Hashable {
    var playhead: Double = 0
    var pixelsPerSecond: Double = 60
    var inPoint: Double? = nil
    var outPoint: Double? = nil
    /// Last export settings used for this project (nil = app defaults).
    var exportSettings: ExportSettings? = nil

    init() {}

    enum CodingKeys: String, CodingKey { case playhead, pixelsPerSecond, inPoint, outPoint, exportSettings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playhead = c.value(.playhead, default: 0.0)
        pixelsPerSecond = c.value(.pixelsPerSecond, default: 60.0)
        inPoint = try? c.decodeIfPresent(Double.self, forKey: .inPoint)
        outPoint = try? c.decodeIfPresent(Double.self, forKey: .outPoint)
        exportSettings = try? c.decodeIfPresent(ExportSettings.self, forKey: .exportSettings)
    }
}

// MARK: - Project

struct EditProject: Codable, Identifiable, Hashable {
    static let currentSchemaVersion = 3

    var id: UUID
    var name: String
    var kind: ProjectKind
    var createdAt: Date
    var modifiedAt: Date
    var settings: ProjectSettings
    var timeline: Timeline
    var story: StoryConfig?
    var merge: MergeConfig?
    var markers: [TimelineMarker]
    var coverAssetID: UUID?
    var compounds: [CompoundClip]
    var studio: StudioState
    var schemaVersion: Int

    init(id: UUID = UUID(), name: String, kind: ProjectKind, settings: ProjectSettings = ProjectSettings()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.settings = settings
        self.timeline = .standard()
        self.story = nil
        self.merge = nil
        self.markers = []
        self.coverAssetID = nil
        self.compounds = []
        self.studio = StudioState()
        self.schemaVersion = EditProject.currentSchemaVersion
    }

    /// Every media asset the project depends on (used for missing-media checks and
    /// deletion safety). Includes assets used inside nested sequences.
    var referencedAssetIDs: Set<UUID> {
        var ids = timeline.referencedAssetIDs
        if let logo = settings.watermark?.imageAssetID { ids.insert(logo) }
        if let story { ids.insert(story.sourceAssetID) }
        if let merge {
            merge.items.forEach { ids.insert($0.assetID) }
            if let music = merge.music { ids.insert(music.assetID) }
        }
        for compound in compounds {
            ids.formUnion(compound.timeline.referencedAssetIDs)
            if let rendered = compound.renderedAssetID { ids.insert(rendered) }
        }
        return ids
    }

    var displayDuration: Double {
        switch kind {
        case .story:
            return story?.segments.filter(\.isIncluded).reduce(0) { $0 + $1.range.duration.seconds } ?? 0
        default:
            return timeline.duration.seconds
        }
    }

    /// The nested sequence whose render is the given media asset, if any.
    func compound(renderedAs assetID: UUID) -> CompoundClip? {
        compounds.first { $0.renderedAssetID == assetID }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, createdAt, modifiedAt, settings, timeline, story, merge, markers, coverAssetID
        case compounds, studio, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = c.value(.name, default: "مشروع")
        kind = c.value(.kind, default: ProjectKind.pro)
        createdAt = c.value(.createdAt, default: Date())
        modifiedAt = c.value(.modifiedAt, default: Date())
        settings = c.value(.settings, default: ProjectSettings())
        timeline = c.value(.timeline, default: Timeline.standard())
        story = try? c.decodeIfPresent(StoryConfig.self, forKey: .story)
        merge = try? c.decodeIfPresent(MergeConfig.self, forKey: .merge)
        markers = c.value(.markers, default: [TimelineMarker]())
        coverAssetID = try? c.decodeIfPresent(UUID.self, forKey: .coverAssetID)
        compounds = c.value(.compounds, default: [CompoundClip]())
        studio = c.value(.studio, default: StudioState())
        schemaVersion = c.value(.schemaVersion, default: EditProject.currentSchemaVersion)
    }
}

/// Lightweight index entry written next to each project for fast listing.
struct ProjectSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var kind: ProjectKind
    var createdAt: Date
    var modifiedAt: Date
    var durationSeconds: Double
    var coverAssetID: UUID?
    var assetIDs: [UUID]
    var itemCount: Int

    init(project: EditProject) {
        id = project.id
        name = project.name
        kind = project.kind
        createdAt = project.createdAt
        modifiedAt = project.modifiedAt
        durationSeconds = project.displayDuration
        coverAssetID = project.coverAssetID ?? project.story?.sourceAssetID ?? project.merge?.items.first?.assetID
            ?? project.timeline.tracks.first?.clips.first?.mediaAssetID
        assetIDs = Array(project.referencedAssetIDs)
        switch project.kind {
        case .story: itemCount = project.story?.segments.filter(\.isIncluded).count ?? 0
        case .merge: itemCount = project.merge?.items.count ?? 0
        case .pro: itemCount = project.timeline.clipCount
        }
    }
}

struct ProjectVersion: Identifiable, Hashable {
    var id: String { url.lastPathComponent }
    let url: URL
    let date: Date
    let summary: ProjectSummary?
}
