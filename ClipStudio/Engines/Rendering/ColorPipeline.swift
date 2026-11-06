//
//  ColorPipeline.swift
//  ClipStudio — Engines/Rendering (color grading, GPU)
//
//  Exposure, temperature/tint, brightness/contrast/saturation, vibrance, hue,
//  tone curve (with highlights/shadows/whites/blacks folded in), lift/gamma/gain
//  wheels (generated 3D LUT), imported .cube LUTs, and chroma key.
//  Neutral parameters skip their filter entirely.
//

import Foundation
import CoreImage

enum ColorPipeline {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func apply(_ c: ColorAdjustments, lut: LUTReference?, to input: CIImage) -> CIImage {
        var image = input
        if !c.isNeutral {
            if c.exposure != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: c.exposure / 50])
            }
            if c.temperature != 0 || c.tint != 0 {
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500 + CGFloat(c.temperature) * 30, y: CGFloat(c.tint) * 1.5),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0)
                ])
            }
            if c.brightness != 0 || c.contrast != 0 || c.saturation != 0 {
                image = image.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: c.brightness / 400,
                    kCIInputContrastKey: 1 + c.contrast / 200,
                    kCIInputSaturationKey: max(0, 1 + c.saturation / 100)
                ])
            }
            if c.vibrance != 0 {
                image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": c.vibrance / 100])
            }
            if c.hue != 0 {
                image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: c.hue / 100 * .pi])
            }
            if c.needsToneCurve {
                let points = toneCurvePoints(c)
                var params: [String: Any] = [:]
                let inputs: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
                for i in 0..<5 { params["inputPoint\(i)"] = CIVector(x: inputs[i], y: CGFloat(points[i])) }
                image = image.applyingFilter("CIToneCurve", parameters: params)
            }
            if !c.wheels.isNeutral, let cube = ColorCubeFactory.shared.wheelsCube(c.wheels) {
                image = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                    "inputCubeDimension": cube.size,
                    "inputCubeData": cube.data,
                    "inputColorSpace": sRGB
                ])
            }
        }
        if let lut, lut.intensity > 0.001, let data = LUTStore.shared.data(for: lut.lutID) {
            let graded = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": data.size,
                "inputCubeData": data.data,
                "inputColorSpace": sRGB
            ])
            image = lut.intensity >= 0.999 ? graded : graded.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: image,
                kCIInputTimeKey: 1 - lut.intensity
            ])
        }
        return image
    }

    /// User curve plus the region sliders, clamped and kept monotonic.
    static func toneCurvePoints(_ c: ColorAdjustments) -> [Double] {
        var y = c.curve.points
        y[0] += c.blacks / 100 * 0.15
        y[1] += c.shadows / 100 * 0.12
        y[3] += c.highlights / 100 * 0.12
        y[4] += c.whites / 100 * 0.15
        for i in 0..<5 { y[i] = min(max(y[i], 0), 1) }
        for i in 1..<5 where y[i] < y[i - 1] { y[i] = y[i - 1] }
        return y
    }
}

struct CubeData {
    let size: Int
    let data: Data
}

/// Generates and caches 3D LUTs for color wheels and chroma keying.
final class ColorCubeFactory: @unchecked Sendable {
    static let shared = ColorCubeFactory()
    private let cache = NSCache<NSString, CubeBox>()

    final class CubeBox {
        let cube: CubeData
        init(_ cube: CubeData) { self.cube = cube }
    }

    func wheelsCube(_ wheels: ColorWheels) -> CubeData? {
        let key = "wheels-\(wheels.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached.cube }
        let size = 24
        var values = [Float](repeating: 0, count: size * size * size * 4)
        func channel(_ x: Double, lift: Double, gamma: Double, gain: Double) -> Float {
            let g = 1 + gain
            let lifted = x + lift * (1 - x)
            let gained = max(0, min(1, lifted * g))
            let exponent = 1 / max(0.2, 1 + gamma)
            return Float(pow(gained, exponent))
        }
        var offset = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rf = Double(r) / Double(size - 1), gf = Double(g) / Double(size - 1), bf = Double(b) / Double(size - 1)
                    values[offset] = channel(rf, lift: wheels.lift.r, gamma: wheels.gamma.r, gain: wheels.gain.r)
                    values[offset + 1] = channel(gf, lift: wheels.lift.g, gamma: wheels.gamma.g, gain: wheels.gain.g)
                    values[offset + 2] = channel(bf, lift: wheels.lift.b, gamma: wheels.gamma.b, gain: wheels.gain.b)
                    values[offset + 3] = 1
                    offset += 4
                }
            }
        }
        let cube = CubeData(size: size, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
        cache.setObject(CubeBox(cube), forKey: key)
        return cube
    }

    func chromaCube(_ settings: ChromaKeySettings) -> CubeData {
        let key = "chroma-\(settings.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached.cube }
        let size = 48
        let keyHue = hue(r: settings.keyColor.r, g: settings.keyColor.g, b: settings.keyColor.b)
        let tolerance = max(0.01, settings.tolerance * 0.5)
        let softness = max(0.001, settings.softness * 0.3)
        var values = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    var rf = Double(r) / Double(size - 1), gf = Double(g) / Double(size - 1), bf = Double(b) / Double(size - 1)
                    let maxC = max(rf, gf, bf), minC = min(rf, gf, bf)
                    let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                    let h = hue(r: rf, g: gf, b: bf)
                    var distance = abs(h - keyHue)
                    distance = min(distance, 1 - distance)
                    var alpha = 1.0
                    if saturation > 0.2 && maxC > 0.15 {
                        if distance < tolerance {
                            alpha = 0
                        } else if distance < tolerance + softness {
                            alpha = (distance - tolerance) / softness
                        }
                    }
                    if alpha > 0 && settings.spillSuppression > 0 && distance < tolerance * 2.5 {
                        let spill = settings.spillSuppression
                        if settings.keyColor.g >= settings.keyColor.r && settings.keyColor.g >= settings.keyColor.b {
                            gf = gf - (gf - min(gf, max(rf, bf))) * spill
                        } else if settings.keyColor.b >= settings.keyColor.r {
                            bf = bf - (bf - min(bf, max(rf, gf))) * spill
                        } else {
                            rf = rf - (rf - min(rf, max(gf, bf))) * spill
                        }
                    }
                    values[offset] = Float(rf * alpha)
                    values[offset + 1] = Float(gf * alpha)
                    values[offset + 2] = Float(bf * alpha)
                    values[offset + 3] = Float(alpha)
                    offset += 4
                }
            }
        }
        let cube = CubeData(size: size, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
        cache.setObject(CubeBox(cube), forKey: key)
        return cube
    }

    private func hue(r: Double, g: Double, b: Double) -> Double {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        guard delta > 0.0001 else { return 0 }
        var h: Double
        if maxC == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h /= 6
        return h < 0 ? h + 1 : h
    }
}

enum ChromaKeyRenderer {
    static func apply(_ settings: ChromaKeySettings, to image: CIImage) -> CIImage {
        let cube = ColorCubeFactory.shared.chromaCube(settings)
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cube.size,
            "inputCubeData": cube.data,
            "inputColorSpace": ColorPipeline.sRGB
        ])
    }
}

// MARK: - LUTs

struct LUTInfo: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var size: Int
    var importedAt: Date
}

enum LUTParseError: LocalizedError {
    case notThreeD
    case invalidSize
    case invalidData(Int)

    var errorDescription: String? {
        switch self {
        case .notThreeD: "الملف ليس LUT ثلاثي الأبعاد (.cube)."
        case .invalidSize: "حجم LUT غير صالح."
        case .invalidData(let line): "بيانات LUT غير صالحة في السطر \(line)."
        }
    }
}

enum LUTParser {
    /// Parses Adobe/Resolve .cube 3D LUTs (red changes fastest — matches CIColorCube).
    static func parse(_ text: String) throws -> CubeData {
        var size = 0
        var domainMin: [Double] = [0, 0, 0]
        var domainMax: [Double] = [1, 1, 1]
        var floats: [Float] = []
        var lineNumber = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = parts.first else { continue }
            switch head.uppercased() {
            case "TITLE":
                continue
            case "LUT_1D_SIZE":
                throw LUTParseError.notThreeD
            case "LUT_3D_SIZE":
                guard parts.count > 1, let value = Int(parts[1]), (2...128).contains(value) else { throw LUTParseError.invalidSize }
                size = value
                floats.reserveCapacity(value * value * value * 4)
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap(Double.init)
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap(Double.init)
            default:
                let values = parts.prefix(3).compactMap(Double.init)
                guard values.count == 3 else {
                    if head.first?.isLetter == true { continue }
                    throw LUTParseError.invalidData(lineNumber)
                }
                for c in 0..<3 {
                    let lo = domainMin.count == 3 ? domainMin[c] : 0
                    let hi = domainMax.count == 3 ? domainMax[c] : 1
                    floats.append(Float((values[c] - lo) / max(0.000001, hi - lo)))
                }
                floats.append(1)
            }
        }
        guard size > 0, floats.count == size * size * size * 4 else { throw LUTParseError.invalidSize }
        return CubeData(size: size, data: floats.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}

/// Thread-safe LUT storage. Index is managed on the main actor by the color workspace (Part 2);
/// the compositor only reads cube data through `data(for:)`.
final class LUTStore: @unchecked Sendable {
    static let shared = LUTStore()
    private let cache = NSCache<NSString, ColorCubeFactory.CubeBox>()
    private let storage = StorageManager.shared

    private var indexURL: URL { storage.lutsDirectory.appendingPathComponent("luts.json") }

    func fileURL(for id: UUID) -> URL { storage.lutsDirectory.appendingPathComponent(id.uuidString + ".cube") }

    func data(for id: UUID) -> CubeData? {
        let key = id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached.cube }
        guard let text = try? String(contentsOf: fileURL(for: id), encoding: .utf8),
              let cube = try? LUTParser.parse(text) else { return nil }
        cache.setObject(ColorCubeFactory.CubeBox(cube), forKey: key)
        return cube
    }

    func list() -> [LUTInfo] {
        JSONStore.load([LUTInfo].self, from: indexURL) ?? []
    }

    /// Validates and copies a .cube file into the library.
    func importLUT(from url: URL, name: String) throws -> LUTInfo {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        let cube = try LUTParser.parse(text)
        let info = LUTInfo(id: UUID(), name: name, size: cube.size, importedAt: Date())
        try text.write(to: fileURL(for: info.id), atomically: true, encoding: .utf8)
        var index = list()
        index.append(info)
        try JSONStore.save(index, to: indexURL)
        return info
    }

    func delete(_ id: UUID) throws {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        cache.removeObject(forKey: id.uuidString as NSString)
        let index = list().filter { $0.id != id }
        try JSONStore.save(index, to: indexURL)
    }
}
