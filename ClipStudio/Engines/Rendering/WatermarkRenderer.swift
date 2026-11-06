//
//  WatermarkRenderer.swift
//  ClipStudio — Engines/Rendering (Text & graphics, Part 3)
//
//  Resolves the project watermark once per composition build (logo decoded with
//  ImageIO) and draws it over every rendered frame at the chosen corner, size and
//  opacity. Text watermarks are rendered with GeneratedContentRenderer (Arabic aware).
//

import Foundation
import CoreImage

/// Immutable, render-thread safe watermark (settings + decoded logo).
final class ResolvedWatermark: @unchecked Sendable {
    let settings: WatermarkSettings
    let logo: CIImage?

    init(settings: WatermarkSettings, logo: CIImage?) {
        self.settings = settings
        self.logo = logo
    }
}

enum WatermarkResolver {
    static func resolve(_ settings: WatermarkSettings?, media: MediaURLMap, maxDimension: CGFloat) async -> ResolvedWatermark? {
        guard let settings, settings.isDrawable else { return nil }
        switch settings.kind {
        case .text:
            return ResolvedWatermark(settings: settings, logo: nil)
        case .image:
            guard let id = settings.imageAssetID, let url = media[id],
                  let logo = StillImageLoader.load(url: url, maxDimension: max(256, maxDimension * CGFloat(min(1, settings.size * 1.5))))
            else { return nil }
            return ResolvedWatermark(settings: settings, logo: logo)
        }
    }
}

enum WatermarkRenderer {
    static func composite(_ watermark: ResolvedWatermark, over canvas: CIImage, canvas size: CGSize) -> CIImage {
        let settings = watermark.settings
        guard var mark = image(for: watermark, canvas: size) else { return canvas }
        let e = mark.extent
        guard e.width > 0, e.height > 0 else { return canvas }
        mark = LayerRenderer.normalizedOrigin(mark)

        let margin = CGFloat(settings.margin) * min(size.width, size.height)
        let x: CGFloat
        let y: CGFloat // Core Image origin is bottom-left.
        switch settings.position {
        case .topLeft:
            x = margin
            y = size.height - margin - e.height
        case .topRight:
            x = size.width - margin - e.width
            y = size.height - margin - e.height
        case .bottomLeft:
            x = margin
            y = margin
        case .bottomRight:
            x = size.width - margin - e.width
            y = margin
        case .center:
            x = (size.width - e.width) / 2
            y = (size.height - e.height) / 2
        }
        mark = mark.transformed(by: CGAffineTransform(translationX: x, y: y))
        let opacity = CGFloat(min(max(settings.opacity, 0), 1))
        if opacity < 0.999 {
            mark = mark.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        }
        return mark.composited(over: canvas).cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func image(for watermark: ResolvedWatermark, canvas: CGSize) -> CIImage? {
        let settings = watermark.settings
        switch settings.kind {
        case .text:
            var content = TextContent(text: settings.text, style: settings.textStyle, animationIn: .none, animationOut: .none)
            content.loop = .none
            return GeneratedContentRenderer.shared.image(for: .text(content), canvas: canvas, localTime: 1, clipDuration: 3600)
        case .image:
            guard let logo = watermark.logo else { return nil }
            let e = logo.extent
            guard e.width > 0, e.height > 0 else { return nil }
            let targetWidth = max(8, CGFloat(settings.size) * canvas.width)
            let scale = targetWidth / e.width
            return logo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
    }
}
