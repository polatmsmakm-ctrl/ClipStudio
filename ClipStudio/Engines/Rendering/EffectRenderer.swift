//
//  EffectRenderer.swift
//  ClipStudio — Engines/Rendering
//
//  GPU effects with keyframable intensity (0…1). All built on Core Image.
//

import Foundation
import CoreImage

enum EffectRenderer {
    static func apply(_ effects: [EffectInstance], to input: CIImage, localTime t: Double, canvas: CGSize) -> CIImage {
        var image = input
        let unit = Double(max(canvas.width, canvas.height)) / 1920
        for effect in effects {
            let amount = min(max(effect.intensity.value(at: t), 0), 1)
            guard amount > 0.001 else { continue }
            let extent = image.extent
            switch effect.kind {
            case .blur:
                image = image.clampedToExtent().applyingGaussianBlur(sigma: amount * 30 * unit).cropped(to: extent)
            case .sharpen:
                image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: amount * 2])
            case .vignette:
                image = image.applyingFilter("CIVignetteEffect", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputRadiusKey: max(extent.width, extent.height) * 0.7,
                    kCIInputIntensityKey: amount * 1.2,
                    "inputFalloff": 0.5
                ])
            case .grain:
                image = grain(image, amount: amount, time: t)
            case .glow:
                image = image.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 12 * unit, kCIInputIntensityKey: amount])
                    .cropped(to: extent)
            case .monochrome:
                image = mix(image, image.applyingFilter("CIPhotoEffectMono"), amount)
            case .sepia:
                image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: amount])
            case .pixelate:
                image = image.applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputScaleKey: max(1, amount * 50 * unit)
                ]).cropped(to: extent)
            case .motionBlur:
                image = image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: amount * 25 * unit, kCIInputAngleKey: 0
                ]).cropped(to: extent)
            case .zoomBlur:
                image = image.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    "inputAmount": amount * 20 * unit
                ]).cropped(to: extent)
            case .chromaticAberration:
                image = chromatic(image, offset: CGFloat(amount * 8 * unit))
            case .filmLook:
                let graded = image
                    .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08, kCIInputSaturationKey: 0.88])
                    .applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: 6900, y: 8), "inputTargetNeutral": CIVector(x: 6500, y: 0)
                    ])
                    .applyingFilter("CIVignetteEffect", parameters: [
                        kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                        kCIInputRadiusKey: max(extent.width, extent.height) * 0.75,
                        kCIInputIntensityKey: 0.5, "inputFalloff": 0.6
                    ])
                image = mix(image, graded, amount)
            case .fadedFilm:
                let faded = image
                    .applyingFilter("CIToneCurve", parameters: [
                        "inputPoint0": CIVector(x: 0, y: 0.12), "inputPoint1": CIVector(x: 0.25, y: 0.3),
                        "inputPoint2": CIVector(x: 0.5, y: 0.52), "inputPoint3": CIVector(x: 0.75, y: 0.74),
                        "inputPoint4": CIVector(x: 1, y: 0.92)
                    ])
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.75])
                image = mix(image, faded, amount)
            case .letterbox:
                image = letterbox(image, amount: amount, canvas: extent)
            }
        }
        return image
    }

    /// Cinematic bars; amount 1 ≈ 2.39:1 framing.
    static func letterbox(_ image: CIImage, amount: Double, canvas: CGRect) -> CIImage {
        let targetHeight = canvas.width / 2.39
        let barHeight = max(0, (canvas.height - targetHeight) / 2) * CGFloat(min(max(amount, 0), 1)) * 2
        guard barHeight > 0.5 else { return image }
        let clamped = min(barHeight, canvas.height / 2.2)
        let top = CIImage(color: .black).cropped(to: CGRect(x: canvas.minX, y: canvas.maxY - clamped, width: canvas.width, height: clamped))
        let bottom = CIImage(color: .black).cropped(to: CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: clamped))
        return top.composited(over: bottom.composited(over: image))
    }

    private static func mix(_ a: CIImage, _ b: CIImage, _ amount: Double) -> CIImage {
        guard amount < 0.999 else { return b }
        return a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: amount])
    }

    private static func grain(_ image: CIImage, amount: Double, time: Double) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let extent = image.extent
        let shift = CGFloat((time * 977).truncatingRemainder(dividingBy: 512))
        let mono = noise
            .transformed(by: CGAffineTransform(translationX: shift, y: shift * 0.7))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount * 0.22))
            ])
            .cropped(to: extent)
        return mono.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: extent)
    }

    private static func chromatic(_ image: CIImage, offset: CGFloat) -> CIImage {
        let extent = image.extent
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        let red = channel(1, 0, 0).transformed(by: CGAffineTransform(translationX: offset, y: 0))
        let green = channel(0, 1, 0)
        let blue = channel(0, 0, 1).transformed(by: CGAffineTransform(translationX: -offset, y: 0))
        return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: extent)
    }
}
