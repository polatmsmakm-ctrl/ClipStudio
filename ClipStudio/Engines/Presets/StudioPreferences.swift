//
//  StudioPreferences.swift
//  ClipStudio — Engines/Presets
//
//  Pro Studio preferences (UserDefaults): snapping, magnetic storyline, ripple
//  delete default, default durations, timeline display, Apple Pencil behaviour,
//  viewer guides and the workspace layout (presets + a saved custom layout).
//

import Foundation
import SwiftUI

enum TrackHeightOption: String, CaseIterable, Codable, Identifiable {
    case compact, regular, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "مضغوط"
        case .regular: "عادي"
        case .large: "كبير"
        }
    }

    func height(for kind: TrackKind) -> CGFloat {
        let base: CGFloat
        switch kind {
        case .video: base = 62
        case .overlay: base = 52
        case .audio: base = 46
        case .text, .subtitle, .adjustment: base = 36
        }
        switch self {
        case .compact: return base * 0.75
        case .regular: return base
        case .large: return base * 1.35
        }
    }
}

enum PencilDoubleTapAction: String, CaseIterable, Codable, Identifiable {
    case toggleBlade, playPause, undo, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleBlade: "تبديل أداة الشفرة"
        case .playPause: "تشغيل / إيقاف"
        case .undo: "تراجع"
        case .none: "بدون"
        }
    }
}

/// Workspace layouts for iPad (and landscape iPhone). Fractions are of the window.
struct StudioLayout: Codable, Hashable {
    var showsMediaPanel: Bool
    var showsInspector: Bool
    /// Height of the viewer area as a fraction of the editor height (0.25…0.75).
    var viewerFraction: Double
    /// Inspector width in points.
    var inspectorWidth: Double
    /// Media panel width in points.
    var mediaPanelWidth: Double

    static let editing = StudioLayout(showsMediaPanel: true, showsInspector: true, viewerFraction: 0.52, inspectorWidth: 340, mediaPanelWidth: 300)
    static let viewerFocus = StudioLayout(showsMediaPanel: false, showsInspector: true, viewerFraction: 0.66, inspectorWidth: 320, mediaPanelWidth: 280)
    static let timelineFocus = StudioLayout(showsMediaPanel: true, showsInspector: false, viewerFraction: 0.36, inspectorWidth: 320, mediaPanelWidth: 280)
    static let minimal = StudioLayout(showsMediaPanel: false, showsInspector: false, viewerFraction: 0.55, inspectorWidth: 320, mediaPanelWidth: 280)

    func clamped() -> StudioLayout {
        var copy = self
        copy.viewerFraction = min(max(viewerFraction, 0.25), 0.75)
        copy.inspectorWidth = min(max(inspectorWidth, 280), 520)
        copy.mediaPanelWidth = min(max(mediaPanelWidth, 240), 460)
        return copy
    }
}

enum StudioLayoutPreset: String, CaseIterable, Identifiable, Codable {
    case editing, viewerFocus, timelineFocus, minimal, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editing: "مونتاج"
        case .viewerFocus: "تركيز على المعاينة"
        case .timelineFocus: "تركيز على الخط الزمني"
        case .minimal: "بسيط"
        case .custom: "تخطيطي المحفوظ"
        }
    }

    var symbol: String {
        switch self {
        case .editing: "rectangle.split.3x1"
        case .viewerFocus: "play.rectangle"
        case .timelineFocus: "timeline.selection"
        case .minimal: "rectangle"
        case .custom: "star"
        }
    }
}

@MainActor
@Observable
final class StudioPreferences {
    private let defaults = UserDefaults.standard

    enum Keys {
        static let snapping = "studio.snapping"
        static let magnetic = "studio.magnetic"
        static let rippleDelete = "studio.rippleDelete"
        static let transitionDuration = "studio.transitionDuration"
        static let imageDuration = "studio.imageDuration"
        static let freezeDuration = "studio.freezeDuration"
        static let generatedDuration = "studio.generatedDuration"
        static let showWaveforms = "studio.showWaveforms"
        static let showFilmstrips = "studio.showFilmstrips"
        static let trackHeight = "studio.trackHeight"
        static let pencilHover = "studio.pencilHover"
        static let pencilDoubleTap = "studio.pencilDoubleTap"
        static let safeGuides = "studio.safeGuides"
        static let grid = "studio.grid"
        static let layoutPreset = "studio.layoutPreset"
        static let customLayout = "studio.customLayout"
        static let currentLayout = "studio.currentLayout"
        static let placement = "studio.placement"
        static let qualityCheck = "studio.qualityCheckBeforeExport"
    }

    var snappingEnabled: Bool { didSet { defaults.set(snappingEnabled, forKey: Keys.snapping) } }
    var magneticTimeline: Bool { didSet { defaults.set(magneticTimeline, forKey: Keys.magnetic) } }
    var rippleDeleteByDefault: Bool { didSet { defaults.set(rippleDeleteByDefault, forKey: Keys.rippleDelete) } }
    var defaultTransitionDuration: Double { didSet { defaults.set(defaultTransitionDuration, forKey: Keys.transitionDuration) } }
    var defaultImageDuration: Double { didSet { defaults.set(defaultImageDuration, forKey: Keys.imageDuration) } }
    var defaultFreezeDuration: Double { didSet { defaults.set(defaultFreezeDuration, forKey: Keys.freezeDuration) } }
    var defaultGeneratedDuration: Double { didSet { defaults.set(defaultGeneratedDuration, forKey: Keys.generatedDuration) } }
    var showWaveforms: Bool { didSet { defaults.set(showWaveforms, forKey: Keys.showWaveforms) } }
    var showFilmstrips: Bool { didSet { defaults.set(showFilmstrips, forKey: Keys.showFilmstrips) } }
    var trackHeight: TrackHeightOption { didSet { defaults.set(trackHeight.rawValue, forKey: Keys.trackHeight) } }
    var pencilHoverScrub: Bool { didSet { defaults.set(pencilHoverScrub, forKey: Keys.pencilHover) } }
    var pencilDoubleTap: PencilDoubleTapAction { didSet { defaults.set(pencilDoubleTap.rawValue, forKey: Keys.pencilDoubleTap) } }
    var showSafeGuides: Bool { didSet { defaults.set(showSafeGuides, forKey: Keys.safeGuides) } }
    var showGrid: Bool { didSet { defaults.set(showGrid, forKey: Keys.grid) } }
    var placementMode: PlacementMode { didSet { defaults.set(placementMode.rawValue, forKey: Keys.placement) } }
    /// Part 4: run the Quality Inspector before exporting and warn about problems.
    var qualityCheckBeforeExport: Bool { didSet { defaults.set(qualityCheckBeforeExport, forKey: Keys.qualityCheck) } }
    var layoutPreset: StudioLayoutPreset { didSet { defaults.set(layoutPreset.rawValue, forKey: Keys.layoutPreset) } }
    /// The layout currently on screen (edited live by dragging dividers).
    var layout: StudioLayout { didSet { save(layout, key: Keys.currentLayout) } }
    private(set) var customLayout: StudioLayout?

    init() {
        let d = UserDefaults.standard
        snappingEnabled = d.object(forKey: Keys.snapping) as? Bool ?? true
        magneticTimeline = d.object(forKey: Keys.magnetic) as? Bool ?? true
        rippleDeleteByDefault = d.object(forKey: Keys.rippleDelete) as? Bool ?? false
        defaultTransitionDuration = d.object(forKey: Keys.transitionDuration) as? Double ?? 0.5
        defaultImageDuration = d.object(forKey: Keys.imageDuration) as? Double ?? 4
        defaultFreezeDuration = d.object(forKey: Keys.freezeDuration) as? Double ?? 2
        defaultGeneratedDuration = d.object(forKey: Keys.generatedDuration) as? Double ?? 5
        showWaveforms = d.object(forKey: Keys.showWaveforms) as? Bool ?? true
        showFilmstrips = d.object(forKey: Keys.showFilmstrips) as? Bool ?? true
        trackHeight = TrackHeightOption(rawValue: d.string(forKey: Keys.trackHeight) ?? "") ?? .regular
        pencilHoverScrub = d.object(forKey: Keys.pencilHover) as? Bool ?? true
        pencilDoubleTap = PencilDoubleTapAction(rawValue: d.string(forKey: Keys.pencilDoubleTap) ?? "") ?? .toggleBlade
        showSafeGuides = d.object(forKey: Keys.safeGuides) as? Bool ?? false
        showGrid = d.object(forKey: Keys.grid) as? Bool ?? false
        placementMode = PlacementMode(rawValue: d.string(forKey: Keys.placement) ?? "") ?? .append
        qualityCheckBeforeExport = d.object(forKey: Keys.qualityCheck) as? Bool ?? true
        layoutPreset = StudioLayoutPreset(rawValue: d.string(forKey: Keys.layoutPreset) ?? "") ?? .editing
        customLayout = Self.load(key: Keys.customLayout)
        layout = Self.load(key: Keys.currentLayout) ?? .editing
    }

    func apply(_ preset: StudioLayoutPreset) {
        layoutPreset = preset
        switch preset {
        case .editing: layout = .editing
        case .viewerFocus: layout = .viewerFocus
        case .timelineFocus: layout = .timelineFocus
        case .minimal: layout = .minimal
        case .custom: layout = customLayout ?? layout
        }
    }

    /// Saves the current panel arrangement as "my layout".
    func saveCurrentAsCustom() {
        customLayout = layout.clamped()
        save(layout.clamped(), key: Keys.customLayout)
        layoutPreset = .custom
    }

    func resetAll() {
        snappingEnabled = true
        magneticTimeline = true
        rippleDeleteByDefault = false
        defaultTransitionDuration = 0.5
        defaultImageDuration = 4
        defaultFreezeDuration = 2
        defaultGeneratedDuration = 5
        showWaveforms = true
        showFilmstrips = true
        trackHeight = .regular
        pencilHoverScrub = true
        pencilDoubleTap = .toggleBlade
        showSafeGuides = false
        showGrid = false
        placementMode = .append
        qualityCheckBeforeExport = true
        apply(.editing)
    }

    private func save(_ layout: StudioLayout, key: String) {
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: key) }
    }

    private static func load(key: String) -> StudioLayout? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StudioLayout.self, from: data)
    }
}
