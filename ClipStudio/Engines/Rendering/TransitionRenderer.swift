//
//  TransitionRenderer.swift
//  ClipStudio — Engines/Rendering
//
//  GPU transitions between the outgoing and incoming layer of one track.
//  `progress` runs 0 → 1 across the overlap of the two clips.
//

import Foundation
import CoreImage

enum TransitionRenderer {
    static func blend(from a: CIImage, to b: CIImage, progress raw: Double, kind: TransitionKind, canvas: CGRect) -> CIImage {
        let p = CGFloat(min(max(raw, 0), 1))
        let clear = CIImage(color: .clear).cropped(to: canvas)
        let from = a.composited(over: clear)
        let to = b.composited(over: clear)
        let w = canvas.width, h = canvas.height
        let result: CIImage

        switch kind {
        case .none:
            result = to
        case .crossDissolve:
            result = dissolve(from, to, p)
        case .fadeBlack:
            result = fadeThrough(from, to, p, color: .black, canvas: canvas)
        case .fadeWhite:
            result = fadeThrough(from, to, p, color: .white, canvas: canvas)
        case .wipeLeft:
            result = to.cropped(to: CGRect(x: canvas.minX + w * (1 - p), y: canvas.minY, width: w * p, height: h)).composited(over: from)
        case .wipeRight:
            result = to.cropped(to: CGRect(x: canvas.minX, y: canvas.minY, width: w * p, height: h)).composited(over: from)
        case .wipeUp:
            result = to.cropped(to: CGRect(x: canvas.minX, y: canvas.minY, width: w, height: h * p)).composited(over: from)
        case .wipeDown:
            result = to.cropped(to: CGRect(x: canvas.minX, y: canvas.minY + h * (1 - p), width: w, height: h * p)).composited(over: from)
        case .slideLeft:
            result = to.transformed(by: CGAffineTransform(translationX: w * (1 - eased(p)), y: 0)).composited(over: from)
        case .slideRight:
            result = to.transformed(by: CGAffineTransform(translationX: -w * (1 - eased(p)), y: 0)).composited(over: from)
        case .slideUp:
            result = to.transformed(by: CGAffineTransform(translationX: 0, y: -h * (1 - eased(p)))).composited(over: from)
        case .slideDown:
            result = to.transformed(by: CGAffineTransform(translationX: 0, y: h * (1 - eased(p)))).composited(over: from)
        case .push:
            let e = eased(p)
            let outgoing = from.transformed(by: CGAffineTransform(translationX: -w * e, y: 0))
            result = to.transformed(by: CGAffineTransform(translationX: w * (1 - e), y: 0)).composited(over: outgoing)
        case .zoomIn:
            result = dissolve(scaled(from, by: 1 + 0.35 * p, canvas: canvas), scaled(to, by: 1.25 - 0.25 * p, canvas: canvas), p)
        case .zoomOut:
            result = dissolve(scaled(from, by: 1 - 0.3 * p, canvas: canvas), scaled(to, by: 0.8 + 0.2 * p, canvas: canvas), p)
        case .blur:
            let radius = Double(sin(p * .pi)) * Double(max(w, h)) * 0.02
            result = dissolve(from.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: canvas),
                              to.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: canvas), p)
        case .swipe:
            result = from.applyingFilter("CISwipeTransition", parameters: [
                kCIInputTargetImageKey: to,
                kCIInputExtentKey: CIVector(cgRect: canvas),
                kCIInputColorKey: CIColor.white,
                kCIInputTimeKey: p,
                kCIInputAngleKey: CGFloat.pi,
                kCIInputWidthKey: w * 0.25,
                "inputOpacity": 0.0
            ])
        case .bars:
            result = from.applyingFilter("CIBarsSwipeTransition", parameters: [
                kCIInputTargetImageKey: to,
                kCIInputAngleKey: CGFloat.pi,
                kCIInputWidthKey: max(10, w / 24),
                "inputBarOffset": 10,
                kCIInputTimeKey: p
            ])
        case .copyMachine:
            result = from.applyingFilter("CICopyMachineTransition", parameters: [
                kCIInputTargetImageKey: to,
                kCIInputExtentKey: CIVector(cgRect: canvas),
                kCIInputColorKey: CIColor(red: 0.89, green: 0.69, blue: 0.29),
                kCIInputTimeKey: p,
                kCIInputAngleKey: 0,
                kCIInputWidthKey: w * 0.12,
                "inputOpacity": 1.2
            ])
        case .flash:
            result = from.applyingFilter("CIFlashTransition", parameters: [
                kCIInputTargetImageKey: to,
                kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                kCIInputExtentKey: CIVector(cgRect: canvas),
                kCIInputColorKey: CIColor(red: 1, green: 0.92, blue: 0.75),
                kCIInputTimeKey: p,
                "inputMaxStriationRadius": 2.58,
                "inputStriationStrength": 0.5,
                "inputStriationContrast": 1.375,
                "inputFadeThreshold": 0.85
            ])
        case .circleReveal:
            let maxRadius = sqrt(w * w + h * h) / 2
            let radius = maxRadius * eased(p)
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: canvas.midX, y: canvas.midY),
                "inputRadius0": max(0, radius - 8),
                "inputRadius1": radius + 8,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black
            ])?.outputImage?.cropped(to: canvas) ?? CIImage(color: .white).cropped(to: canvas)
            result = to.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: from,
                kCIInputMaskImageKey: mask
            ])
        case .spin:
            let angleOut = p * .pi / 2
            let angleIn = -(1 - p) * .pi / 2
            result = dissolve(rotated(from, by: angleOut, scale: 1 - 0.35 * p, canvas: canvas),
                              rotated(to, by: angleIn, scale: 0.65 + 0.35 * p, canvas: canvas), p)
        }
        return result.cropped(to: canvas)
    }

    private static func eased(_ p: CGFloat) -> CGFloat {
        CGFloat(Easing.easeInOut.apply(Double(p)))
    }

    private static func dissolve(_ a: CIImage, _ b: CIImage, _ p: CGFloat) -> CIImage {
        a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: p])
    }

    private static func fadeThrough(_ a: CIImage, _ b: CIImage, _ p: CGFloat, color: CIColor, canvas: CGRect) -> CIImage {
        let solid = CIImage(color: color).cropped(to: canvas)
        return p < 0.5 ? dissolve(a, solid, p * 2) : dissolve(solid, b, (p - 0.5) * 2)
    }

    private static func scaled(_ image: CIImage, by scale: CGFloat, canvas: CGRect) -> CIImage {
        let t = CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: canvas.midX, y: canvas.midY))
        return image.transformed(by: t)
    }

    private static func rotated(_ image: CIImage, by angle: CGFloat, scale: CGFloat, canvas: CGRect) -> CIImage {
        let t = CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: canvas.midX, y: canvas.midY))
        return image.transformed(by: t)
    }
}
