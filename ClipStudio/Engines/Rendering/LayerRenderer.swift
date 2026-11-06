//
//  LayerRenderer.swift
//  ClipStudio — Engines/Rendering
//
//  Turns one clip's source image into a canvas-space layer:
//  crop → flip → color/LUT → chroma key → effects → mask → fit → keyframed
//  transform (position/scale/stretch/rotation around the anchor) → opacity.
//  Generated layers also get their entrance/exit/loop animation (blur, wipe,
//  rotation… — Part 3). Part 4: video stabilization and horizon leveling before
//  the crop; masks can follow a tracked subject. Also: blend modes and adjustment
//  layers.
//

import Foundation
import CoreImage

enum LayerRole {
    case media, generated, solid
}

enum LayerRenderer {
    static func render(source: CIImage, clip: Clip, role: LayerRole, localTime t: Double,
                       clipDuration: Double, canvas: CGSize) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        var image = source

        if role == .media, let stabilization = clip.stabilization, stabilization.isEnabled,
           let sourceTime = SpeedMapping.sourceTime(of: clip, local: t),
           let correction = StabilizationStore.shared.correction(assetID: stabilization.assetID, strength: stabilization.strength,
                                                                 at: sourceTime) {
            image = stabilized(image, dx: correction.x, dy: correction.y, zoom: stabilization.zoom)
        }

        if role == .media, let horizon = clip.horizon, horizon.isEnabled,
           let sourceTime = SpeedMapping.sourceTime(of: clip, local: t),
           let angle = HorizonStore.shared.angle(assetID: horizon.assetID, smoothing: horizon.smoothing, at: sourceTime) {
            image = leveled(image, angle: -angle * min(1, max(0, horizon.strength)))
        }

        if role == .media {
            let crop = clip.crop.value(at: t).clamped()
            if !crop.isFull {
                image = image.cropped(to: crop.ciRect(in: image.extent))
                image = normalizedOrigin(image)
            }
        }

        if clip.transform.flipHorizontal || clip.transform.flipVertical {
            let e = image.extent
            let flip = CGAffineTransform(a: clip.transform.flipHorizontal ? -1 : 1, b: 0, c: 0,
                                         d: clip.transform.flipVertical ? -1 : 1,
                                         tx: clip.transform.flipHorizontal ? e.width + 2 * e.minX : 0,
                                         ty: clip.transform.flipVertical ? e.height + 2 * e.minY : 0)
            image = image.transformed(by: flip)
        }

        if role != .generated {
            image = ColorPipeline.apply(clip.color, lut: clip.lut, to: image)
        }
        if let key = clip.chromaKey, key.isEnabled, role == .media {
            image = ChromaKeyRenderer.apply(key, to: image)
        }
        let effects = clip.effects.filter { $0.isEnabled && $0.kind != .letterbox }
        if !effects.isEmpty {
            image = EffectRenderer.apply(effects, to: image, localTime: t, canvas: canvas)
        }
        if let mask = clip.mask, mask.isEnabled {
            image = MaskRenderer.apply(mask.resolved(at: t), to: image)
        }

        var background: CIImage?
        var placed: CIImage
        switch role {
        case .media:
            let fitted = fit(image, mode: clip.fitMode, canvas: canvas)
            placed = fitted.foreground
            background = fitted.background
        case .generated:
            placed = centered(image, in: canvas)
        case .solid:
            placed = image
        }

        // Geometry uses the un-animated extent so wipes and blurs never shift the layer.
        let geometryExtent = placed.extent
        let animation = role == .generated ? TextAnimator.state(for: clip, localTime: t, duration: clipDuration) : .identity
        if role == .generated && !animation.isIdentity {
            placed = animate(placed, with: animation, clip: clip, canvas: canvas)
        }

        let position = clip.transform.position.value(at: t)
        let scale = clip.transform.scale.value(at: t) * animation.scale
        let rotation = clip.transform.rotation.value(at: t) + animation.rotation
        let opacity = clip.transform.opacity.value(at: t) * animation.opacity
        let finalPosition = Vec2(x: position.x + animation.offset.x, y: position.y + animation.offset.y)

        var result = placed.transformed(by: matrix(extent: geometryExtent, anchor: clip.transform.anchor, scale: scale,
                                                    stretch: clip.transform.stretch,
                                                    rotationDegrees: rotation, position: finalPosition, canvas: canvas))
        if let background { result = result.composited(over: background) }

        if let letterbox = clip.effects.first(where: { $0.isEnabled && $0.kind == .letterbox }) {
            result = EffectRenderer.letterbox(result, amount: letterbox.intensity.value(at: t), canvas: canvasRect)
        }
        if opacity < 0.999 {
            result = result.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity)))])
        }
        return result.cropped(to: canvasRect)
    }

    /// Applies an adjustment clip's grading and effects to everything rendered below it.
    static func applyAdjustment(clip: Clip, to canvas: CIImage, localTime: Double, canvas size: CGSize) -> CIImage {
        var adjusted = ColorPipeline.apply(clip.color, lut: clip.lut, to: canvas)
        let effects = clip.effects.filter(\.isEnabled)
        if !effects.isEmpty { adjusted = EffectRenderer.apply(effects, to: adjusted, localTime: localTime, canvas: size) }
        let opacity = clip.transform.opacity.value(at: localTime)
        let rect = CGRect(origin: .zero, size: size)
        if opacity >= 0.999 { return adjusted.cropped(to: rect) }
        return adjusted.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: canvas,
            kCIInputTimeKey: 1 - max(0, opacity)
        ]).cropped(to: rect)
    }

    // MARK: Geometry

    static func normalizedOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    static func centered(_ image: CIImage, in canvas: CGSize) -> CIImage {
        let e = image.extent
        return image.transformed(by: CGAffineTransform(translationX: (canvas.width - e.width) / 2 - e.minX,
                                                       y: (canvas.height - e.height) / 2 - e.minY))
    }

    static func fit(_ image: CIImage, mode: FitMode, canvas: CGSize) -> (foreground: CIImage, background: CIImage?) {
        let e = image.extent
        guard e.width > 0, e.height > 0, e.width.isFinite, e.height.isFinite else { return (image, nil) }
        let sx = canvas.width / e.width
        let sy = canvas.height / e.height
        func placed(_ scaleX: CGFloat, _ scaleY: CGFloat) -> CIImage {
            centered(image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)), in: canvas)
        }
        switch mode {
        case .fit:
            return (placed(min(sx, sy), min(sx, sy)), nil)
        case .fill:
            return (placed(max(sx, sy), max(sx, sy)), nil)
        case .stretch:
            return (placed(sx, sy), nil)
        case .fitBlur:
            let foreground = placed(min(sx, sy), min(sx, sy))
            guard abs(sx - sy) > 0.01 else { return (foreground, nil) }
            let fillScale = max(sx, sy)
            let radius = Double(max(canvas.width, canvas.height)) * 0.03
            let background = placed(fillScale, fillScale)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: radius)
                .cropped(to: CGRect(origin: .zero, size: canvas))
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.1, kCIInputSaturationKey: 1.05])
            return (foreground, background)
        }
    }

    /// Shifts a frame by the stabilization correction (normalized, +y down) and zooms to hide the edges.
    static func stabilized(_ image: CIImage, dx: Double, dy: Double, zoom: Double) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let z = CGFloat(max(1, zoom))
        let transform = CGAffineTransform(translationX: CGFloat(dx) * e.width, y: -CGFloat(dy) * e.height)
            .concatenating(CGAffineTransform(translationX: -e.midX, y: -e.midY))
            .concatenating(CGAffineTransform(scaleX: z, y: z))
            .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
        return image.clampedToExtent().transformed(by: transform).cropped(to: e)
    }

    /// Rotates a frame about its center by `angle` (radians, CCW) and zooms to keep it full-frame.
    static func leveled(_ image: CIImage, angle: Double) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, abs(angle) > 0.0005 else { return image }
        let scale = CGFloat(HorizonAnalyzer.coverScale(angle: angle, width: Double(e.width), height: Double(e.height)))
        let transform = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(angle)))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
        return image.clampedToExtent().transformed(by: transform).cropped(to: e)
    }

    /// Blur / wipe parts of an entrance-exit animation, applied to the centered layer.
    private static func animate(_ image: CIImage, with state: TextAnimator.State, clip: Clip, canvas: CGSize) -> CIImage {
        var result = image
        let e = image.extent
        if state.blur > 0.001 {
            // The layer has transparent surroundings, so blurring spreads into clear pixels.
            let sigma = state.blur * Double(canvas.height) * 0.02
            let margin = CGFloat(sigma) * 3
            result = result.applyingGaussianBlur(sigma: sigma).cropped(to: e.insetBy(dx: -margin, dy: -margin))
        }
        if state.reveal < 0.999 {
            var rtl = false
            if case .text(let content) = clip.source { rtl = ScriptDirection.isRightToLeft(content.text) }
            let width = e.width * CGFloat(max(0, state.reveal))
            let visible = rtl ? CGRect(x: e.maxX - width, y: e.minY, width: width, height: e.height)
                              : CGRect(x: e.minX, y: e.minY, width: width, height: e.height)
            result = result.cropped(to: visible)
        }
        return result
    }

    /// Scale/stretch/rotate around the anchor, then move the image center to `position` (top-left normalized).
    static func matrix(extent e: CGRect, anchor: Vec2, scale: Double, stretch: Vec2 = .one, rotationDegrees: Double,
                       position: Vec2, canvas: CGSize) -> CGAffineTransform {
        let pivot = CGPoint(x: e.minX + CGFloat(anchor.x) * e.width, y: e.maxY - CGFloat(anchor.y) * e.height)
        let target = CGPoint(x: CGFloat(position.x) * canvas.width, y: CGFloat(1 - position.y) * canvas.height)
        let shift = CGPoint(x: target.x - e.midX, y: target.y - e.midY)
        let radians = -CGFloat(rotationDegrees) * .pi / 180
        let s = CGFloat(max(0.001, scale))
        let sx = s * CGFloat(min(max(stretch.x, 0.01), 20))
        let sy = s * CGFloat(min(max(stretch.y, 0.01), 20))
        return CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: pivot.x + shift.x, y: pivot.y + shift.y))
    }
}

// MARK: - Blend

enum BlendRenderer {
    static func composite(_ foreground: CIImage, over background: CIImage, mode: BlendMode) -> CIImage {
        guard let name = mode.ciFilterName else { return foreground.composited(over: background) }
        return foreground.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: background])
    }
}

// MARK: - Mask

enum MaskRenderer {
    static func apply(_ mask: MaskSettings, to image: CIImage) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let center = CGPoint(x: e.minX + CGFloat(mask.center.x) * e.width, y: e.maxY - CGFloat(mask.center.y) * e.height)
        let size = CGSize(width: CGFloat(mask.size.x) * e.width, height: CGFloat(mask.size.y) * e.height)
        let feather = CGFloat(min(max(mask.feather, 0), 1))
        let black = CIImage(color: .black).cropped(to: e)
        var shape: CIImage

        switch mask.shape {
        case .rectangle:
            let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            shape = CIImage(color: .white).cropped(to: rect)
            if feather > 0 { shape = shape.applyingGaussianBlur(sigma: Double(feather * min(size.width, size.height) * 0.25)) }
            shape = shape.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(mask.rotation) * .pi / 180)
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        case .ellipse:
            let radius: CGFloat = 100
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": radius * (1 - feather),
                "inputRadius1": radius,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black
            ])?.outputImage ?? black
            shape = gradient.cropped(to: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
                .transformed(by: CGAffineTransform(scaleX: max(1, size.width) / (radius * 2), y: max(1, size.height) / (radius * 2))
                    .concatenating(CGAffineTransform(rotationAngle: -CGFloat(mask.rotation) * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        case .linear:
            let angle = -CGFloat(mask.rotation) * .pi / 180
            let half = max(1, size.height / 2)
            let soft = max(1, half * max(feather, 0.02))
            let dx = sin(angle), dy = cos(angle)
            let p0 = CGPoint(x: center.x - dx * soft, y: center.y - dy * soft)
            let p1 = CGPoint(x: center.x + dx * soft, y: center.y + dy * soft)
            shape = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: p0),
                "inputPoint1": CIVector(cgPoint: p1),
                "inputColor0": CIColor.black,
                "inputColor1": CIColor.white
            ])?.outputImage ?? black
        }

        var maskImage = shape.composited(over: black).cropped(to: e)
        if mask.invert { maskImage = maskImage.applyingFilter("CIColorInvert").cropped(to: e) }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: e),
            kCIInputMaskImageKey: maskImage
        ])
    }
}
