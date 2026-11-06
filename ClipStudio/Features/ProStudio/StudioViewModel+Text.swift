//
//  StudioViewModel+Text.swift
//  ClipStudio — Features/ProStudio (Text & graphics, Part 3)
//
//  Adding titles, lower thirds, plain text, shapes, stickers and image overlays to
//  their own tracks at the playhead (or over the selection / in-out range), text
//  style presets, and the project watermark.
//

import Foundation
import SwiftUI

extension StudioViewModel {

    /// Start and length for a new layer: the selection, the in/out range, or the playhead.
    func layerRange(defaultDuration: Double) -> (start: Double, duration: Double) {
        let visual = selectedClips.filter { clip in
            if case .media = clip.source { return true }
            if case .image = clip.source { return true }
            return false
        }
        if let start = visual.map(\.start.seconds).min(), let end = visual.map(\.end.seconds).max(), end - start > frameDuration {
            return (start, end - start)
        }
        if let range = inOutRange, range.1 - range.0 > frameDuration { return (range.0, range.1 - range.0) }
        return (currentTime, defaultDuration)
    }

    /// Inserts a generated layer on a free track of `kind`, selects it and opens `tab`.
    @discardableResult
    func insertGeneratedLayer(_ source: ClipSource, name: String, kind: TrackKind, duration: Double,
                              position: Vec2? = nil, tab: InspectorTab) -> UUID? {
        let range = layerRange(defaultDuration: duration)
        let length = max(frameDuration, (range.duration * frameRate).rounded() / frameRate)
        var clip = Clip(name: name, source: source, start: TimeValue(seconds: range.start), duration: TimeValue(seconds: length))
        if let position { clip.transform.position = KeyframedValue(position) }
        var placed: UUID?
        edit("إضافة " + name) { timeline, context in
            placed = try TimelineEngine.insertLayer(clip, kind: kind, at: range.start, in: &timeline, context: context)
        }
        guard let placed else { return nil }
        selection = [placed]
        if let index = TimelineEngine.trackIndex(of: placed, in: timeline) { selectedTrackIndex = index }
        inspectorTab = tab
        Haptics.success()
        return placed
    }

    // MARK: Text

    func addTitle(_ template: TitleTemplate, text: String, subtitle: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (template.design.usesSubtitle && !second.isEmpty) else {
            env.toasts.show("اكتب النص أولاً.", style: .info)
            return
        }
        let content = template.content(text: trimmed, subtitle: second)
        let rtl = ScriptDirection.isRightToLeft(trimmed + second)
        insertGeneratedLayer(.text(content), name: CaptionBuilder.shortName(trimmed.isEmpty ? second : trimmed), kind: .text,
                             duration: template.duration, position: template.position(rightToLeft: rtl), tab: .text)
    }

    /// Applies a text look to the selected text layers (keeps text, design and animation).
    func applyTextStyle(_ style: TextStyle, name: String) {
        updateSelection("نمط النص: " + name) { clip in
            guard case .text(var content) = clip.source else { return }
            content.style = style
            clip.source = .text(content)
        }
        endContinuousEdit()
    }

    /// Edits the text content of a clip (keeps caption word timing in sync).
    func updateText(_ clipID: UUID, name: String, coalesce: String? = nil, _ change: @escaping (inout TextContent) -> Void) {
        updateClip(clipID, name: name, coalesce: coalesce) { clip in
            guard case .text(var content) = clip.source else { return }
            change(&content)
            clip.source = .text(content)
        }
    }

    /// Updates the text of the selected text layers (same change on each).
    func updateSelectedText(_ name: String, coalesce: String? = nil, _ change: @escaping (inout TextContent) -> Void) {
        updateSelection(name, coalesce: coalesce) { clip in
            guard case .text(var content) = clip.source else { return }
            change(&content)
            clip.source = .text(content)
        }
    }

    // MARK: Graphics

    func addShape(_ kind: ShapeKind, color: RGBAColor) {
        var shape = ShapeContent()
        shape.kind = kind
        shape.fill = color
        switch kind {
        case .line:
            shape.size = Vec2(x: 0.4, y: 0.02)
            shape.strokeWidth = 0.008
        case .ellipse, .star, .heart:
            let side = 0.22
            shape.size = Vec2(x: side * canvasSize.height / max(1, canvasSize.width), y: side)
        case .arrow:
            shape.size = Vec2(x: 0.3, y: 0.12)
        case .bubble:
            shape.size = Vec2(x: 0.42, y: 0.22)
        default:
            break
        }
        insertGeneratedLayer(.shape(shape), name: kind.title, kind: .overlay, duration: prefs.defaultGeneratedDuration, tab: .graphic)
    }

    func addSticker(symbol: String, isEmoji: Bool, color: RGBAColor) {
        var sticker = StickerContent(symbolName: symbol, isEmoji: isEmoji)
        sticker.color = color
        insertGeneratedLayer(.sticker(sticker), name: isEmoji ? symbol : "ملصق", kind: .overlay,
                             duration: prefs.defaultGeneratedDuration, tab: .graphic)
    }

    /// Picture-in-picture image overlay (logo, photo) at 40 % size.
    func addImageOverlay(_ asset: MediaAsset) {
        guard asset.kind == .image else { return }
        let range = layerRange(defaultDuration: prefs.defaultGeneratedDuration)
        var clip = Clip(name: asset.displayName, source: .image(asset.id), start: TimeValue(seconds: range.start),
                        duration: TimeValue(seconds: max(frameDuration, range.duration)))
        clip.transform.scale = KeyframedValue(0.4)
        var placed: UUID?
        edit("إضافة صورة") { timeline, context in
            placed = try TimelineEngine.insertLayer(clip, kind: .overlay, at: range.start, in: &timeline, context: context)
        }
        if let placed {
            selection = [placed]
            inspectorTab = .transform
        }
    }

    // MARK: Watermark

    func setWatermark(_ watermark: WatermarkSettings?, coalesce: Bool = false) {
        editProject("العلامة المائية", coalesce: coalesce ? "watermark" : nil) { project in
            project.settings.watermark = watermark
        }
    }
}
