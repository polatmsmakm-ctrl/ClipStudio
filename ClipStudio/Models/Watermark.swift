//
//  Watermark.swift
//  ClipStudio — Models (Text & graphics, Part 3)
//
//  A project-wide watermark (text or a logo image from the media library) drawn
//  on top of every frame of the preview and of every export of the project.
//

import Foundation

enum WatermarkKind: String, Codable, CaseIterable, Hashable {
    case text, image

    var title: String { self == .text ? "نص" : "شعار (صورة)" }
}

/// Canvas corner (physical left/right, independent of the UI language).
enum WatermarkPosition: String, Codable, CaseIterable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight, center

    var title: String {
        switch self {
        case .topLeft: "أعلى اليسار"
        case .topRight: "أعلى اليمين"
        case .bottomLeft: "أسفل اليسار"
        case .bottomRight: "أسفل اليمين"
        case .center: "الوسط"
        }
    }

    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        case .center: "circle.grid.cross"
        }
    }
}

struct WatermarkSettings: Codable, Hashable {
    var isEnabled = true
    var kind: WatermarkKind = .text
    var text = ""
    var imageAssetID: UUID? = nil
    var textStyle: TextStyle = {
        var style = TextStyle()
        style.weight = .semibold
        style.sizeRatio = 0.032
        style.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.5)
        style.shadowRadius = 4
        style.maxWidthRatio = 0.6
        return style
    }()
    var position: WatermarkPosition = .bottomRight
    /// Logo width relative to the canvas width.
    var size: Double = 0.16
    var opacity: Double = 0.8
    /// Distance from the edges relative to the canvas' shorter side.
    var margin: Double = 0.035

    enum CodingKeys: String, CodingKey { case isEnabled, kind, text, imageAssetID, textStyle, position, size, opacity, margin }

    /// True when there is something to draw.
    var isDrawable: Bool {
        guard isEnabled else { return false }
        switch kind {
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image: return imageAssetID != nil
        }
    }
}

extension WatermarkSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = c.value(.isEnabled, default: true)
        kind = c.value(.kind, default: WatermarkKind.text)
        text = c.value(.text, default: "")
        imageAssetID = try? c.decodeIfPresent(UUID.self, forKey: .imageAssetID)
        textStyle = c.value(.textStyle, default: textStyle)
        position = c.value(.position, default: WatermarkPosition.bottomRight)
        size = c.value(.size, default: 0.16)
        opacity = c.value(.opacity, default: 0.8)
        margin = c.value(.margin, default: 0.035)
    }
}
