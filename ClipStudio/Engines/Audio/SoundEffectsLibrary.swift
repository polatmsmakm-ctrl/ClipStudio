//
//  SoundEffectsLibrary.swift
//  ClipStudio — Engines/Audio (Audio Studio, Part 3)
//
//  A built-in sound-effects library synthesized on the device (no bundled or
//  downloaded audio): whooshes, risers, pops, clicks, bells, impacts, UI sounds,
//  typing, shutter, heartbeat, glitch… Each effect is rendered once to a 48 kHz
//  16-bit WAV (cached for previews), imported into the media library the first
//  time it is used, and remembered in State/sfx.json so it is never duplicated.
//

import Foundation
import AVFoundation

enum SoundEffectCategory: String, CaseIterable, Identifiable {
    case transitions, interface, bells, hits, foley

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transitions: "انتقالات"
        case .interface: "واجهة وتنبيهات"
        case .bells: "أجراس"
        case .hits: "ضربات وإيقاع"
        case .foley: "أصوات يومية"
        }
    }
}

enum SoundEffect: String, CaseIterable, Identifiable {
    case whoosh, swipe, riser, swooshUp
    case pop, click, notification, coin, success, error
    case ding, chime
    case impact, kick, heartbeat, glitch
    case typing, shutter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whoosh: "مرور سريع"
        case .swipe: "سحب"
        case .riser: "تصاعد"
        case .swooshUp: "صعود هوائي"
        case .pop: "فرقعة"
        case .click: "نقرة"
        case .notification: "تنبيه"
        case .coin: "عملة"
        case .success: "نجاح"
        case .error: "خطأ"
        case .ding: "جرس"
        case .chime: "رنين"
        case .impact: "ارتطام"
        case .kick: "طبلة"
        case .heartbeat: "نبض قلب"
        case .glitch: "تشويش رقمي"
        case .typing: "كتابة"
        case .shutter: "غالق كاميرا"
        }
    }

    var symbol: String {
        switch self {
        case .whoosh: "wind"
        case .swipe: "hand.draw"
        case .riser: "chart.line.uptrend.xyaxis"
        case .swooshUp: "arrow.up.forward"
        case .pop: "bubble.left"
        case .click: "cursorarrow.click"
        case .notification: "bell.badge"
        case .coin: "dollarsign.circle"
        case .success: "checkmark.seal"
        case .error: "xmark.octagon"
        case .ding: "bell"
        case .chime: "music.note"
        case .impact: "burst"
        case .kick: "circle.circle"
        case .heartbeat: "heart"
        case .glitch: "waveform.path.badge.minus"
        case .typing: "keyboard"
        case .shutter: "camera.aperture"
        }
    }

    var category: SoundEffectCategory {
        switch self {
        case .whoosh, .swipe, .riser, .swooshUp: .transitions
        case .pop, .click, .notification, .coin, .success, .error: .interface
        case .ding, .chime: .bells
        case .impact, .kick, .heartbeat, .glitch: .hits
        case .typing, .shutter: .foley
        }
    }

    var duration: Double {
        switch self {
        case .whoosh: 0.9
        case .swipe: 0.4
        case .riser: 2.5
        case .swooshUp: 1.4
        case .pop: 0.18
        case .click: 0.06
        case .notification: 0.55
        case .coin: 0.5
        case .success: 0.8
        case .error: 0.45
        case .ding: 1.8
        case .chime: 1.6
        case .impact: 1.4
        case .kick: 0.5
        case .heartbeat: 1.0
        case .glitch: 0.6
        case .typing: 1.6
        case .shutter: 0.35
        }
    }
}

// MARK: - Synthesis

enum SoundEffectSynth {
    static let sampleRate = 48_000.0

    /// Deterministic noise (same sound every time).
    private struct Noise {
        var state: UInt32
        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state >> 8) / Double(1 << 24) * 2 - 1
        }
    }

    static func samples(for effect: SoundEffect) -> [Float] {
        let count = Int(effect.duration * sampleRate)
        var out = [Float](repeating: 0, count: count)
        var noise = Noise(state: UInt32(truncatingIfNeeded: effect.rawValue.hashValueStable))
        let sr = sampleRate
        func t(_ i: Int) -> Double { Double(i) / sr }
        func env(_ x: Double, attack: Double, decay: Double) -> Double {
            if x < attack { return x / max(attack, 1e-6) }
            return exp(-(x - attack) / max(decay, 1e-6))
        }

        switch effect {
        case .whoosh, .swipe, .swooshUp:
            // Band-passed noise with a moving center frequency (state-variable filter).
            var low = 0.0, band = 0.0
            let length = effect.duration
            for i in 0..<count {
                let x = t(i) / length
                let center: Double
                switch effect {
                case .swooshUp: center = 300 + 3_500 * x * x
                case .swipe: center = 2_500 - 1_600 * x
                default: center = 400 + 2_400 * sin(.pi * x)
                }
                let f = 2 * sin(.pi * center / sr)
                let q = 0.35
                let input = noise.next()
                low += f * band
                let high = input - low - q * band
                band += f * high
                let shape = sin(.pi * min(1, x * 1.05))
                out[i] = Float(band * 0.9 * shape * shape)
            }
        case .riser:
            var phase = 0.0
            for i in 0..<count {
                let x = t(i) / effect.duration
                let freq = 180 + 1_400 * x * x
                phase += 2 * .pi * freq / sr
                let tremolo = 0.6 + 0.4 * sin(2 * .pi * (4 + 18 * x) * t(i))
                let tone = sin(phase) + 0.35 * sin(phase * 2.01)
                let air = noise.next() * 0.25 * x
                out[i] = Float((tone * 0.35 + air) * tremolo * x * (x < 0.97 ? 1 : (1 - x) / 0.03))
            }
        case .pop:
            var phase = 0.0
            for i in 0..<count {
                let x = t(i)
                let freq = 220 + 900 * exp(-x * 45)
                phase += 2 * .pi * freq / sr
                out[i] = Float(sin(phase) * env(x, attack: 0.002, decay: 0.035) * 0.9)
            }
        case .click:
            for i in 0..<count {
                let x = t(i)
                out[i] = Float(noise.next() * env(x, attack: 0.0005, decay: 0.006) * 0.8
                               + sin(2 * .pi * 3_200 * x) * env(x, attack: 0.0005, decay: 0.01) * 0.4)
            }
        case .notification:
            for i in 0..<count {
                let x = t(i)
                let first = x < 0.22 ? sin(2 * .pi * 880 * x) * env(x, attack: 0.005, decay: 0.12) : 0
                let y = x - 0.2
                let second = y > 0 ? sin(2 * .pi * 1_318.5 * y) * env(y, attack: 0.005, decay: 0.16) : 0
                out[i] = Float((first + second) * 0.45)
            }
        case .coin:
            for i in 0..<count {
                let x = t(i)
                let freq = x < 0.08 ? 987.8 : 1_318.5
                let square: Double = sin(2 * .pi * freq * x) >= 0 ? 1 : -1
                out[i] = Float(square * 0.18 * (x < 0.08 ? 1 : env(x - 0.08, attack: 0.001, decay: 0.15)))
            }
        case .success:
            let notes: [(Double, Double)] = [(0, 523.25), (0.12, 659.25), (0.24, 783.99)]
            for i in 0..<count {
                let x = t(i)
                var value = 0.0
                for note in notes where x >= note.0 {
                    let y = x - note.0
                    value += (sin(2 * .pi * note.1 * y) + 0.3 * sin(4 * .pi * note.1 * y)) * env(y, attack: 0.005, decay: 0.25)
                }
                out[i] = Float(value * 0.25)
            }
        case .error:
            for i in 0..<count {
                let x = t(i)
                let square: Double = sin(2 * .pi * 140 * x) >= 0 ? 1 : -1
                let gate: Double = x < 0.18 || (x > 0.24 && x < 0.42) ? 1 : 0
                out[i] = Float(square * gate * 0.2)
            }
        case .ding, .chime:
            let partials: [(Double, Double, Double)] = effect == .ding
                ? [(1, 1, 1.2), (2.76, 0.5, 0.6), (5.4, 0.25, 0.35), (8.93, 0.12, 0.2)]
                : [(1, 1, 0.9), (2, 0.4, 0.5), (3, 0.2, 0.3)]
            let base = effect == .ding ? 1_046.5 : 784.0
            for i in 0..<count {
                let x = t(i)
                var value = 0.0
                for partial in partials {
                    value += sin(2 * .pi * base * partial.0 * x) * partial.1 * env(x, attack: 0.002, decay: partial.2)
                }
                if effect == .chime, x > 0.18 {
                    let y = x - 0.18
                    value += sin(2 * .pi * 1_046.5 * y) * env(y, attack: 0.002, decay: 0.7) * 0.8
                }
                out[i] = Float(value * 0.28)
            }
        case .impact:
            var phase = 0.0
            var low = 0.0
            for i in 0..<count {
                let x = t(i)
                let freq = 38 + 90 * exp(-x * 12)
                phase += 2 * .pi * freq / sr
                low += 0.08 * (noise.next() - low)
                out[i] = Float((sin(phase) * env(x, attack: 0.003, decay: 0.45) + low * 3 * env(x, attack: 0.001, decay: 0.12)) * 0.8)
            }
        case .kick:
            var phase = 0.0
            for i in 0..<count {
                let x = t(i)
                let freq = 45 + 110 * exp(-x * 30)
                phase += 2 * .pi * freq / sr
                out[i] = Float(sin(phase) * env(x, attack: 0.001, decay: 0.16) * 0.95)
            }
        case .heartbeat:
            for i in 0..<count {
                var value = 0.0
                for start in [0.0, 0.28] {
                    let y = t(i) - start
                    guard y >= 0 else { continue }
                    value += sin(2 * .pi * (48 + 30 * exp(-y * 25)) * y) * env(y, attack: 0.004, decay: 0.09) * (start == 0 ? 1 : 0.75)
                }
                out[i] = Float(value * 0.9)
            }
        case .glitch:
            var held = 0.0
            var holdLeft = 0
            for i in 0..<count {
                if holdLeft <= 0 {
                    held = noise.next() > 0.2 ? (sin(2 * .pi * (200 + 1_800 * abs(noise.next())) * t(i)) >= 0 ? 0.5 : -0.5) : 0
                    holdLeft = Int(sr * (0.004 + 0.03 * abs(noise.next())))
                }
                holdLeft -= 1
                let crushed = (held * 4).rounded() / 4
                out[i] = Float(crushed * 0.5 * (t(i) < effect.duration - 0.02 ? 1 : 0))
            }
        case .typing:
            var nextKey = 0.0
            var keyStarts: [Double] = []
            while nextKey < effect.duration - 0.1 {
                keyStarts.append(nextKey)
                nextKey += 0.07 + 0.11 * abs(noise.next())
            }
            for i in 0..<count {
                let x = t(i)
                var value = 0.0
                for start in keyStarts where x >= start && x - start < 0.05 {
                    let y = x - start
                    value += noise.next() * env(y, attack: 0.0005, decay: 0.008) * 0.6
                        + sin(2 * .pi * 1_900 * y) * env(y, attack: 0.0005, decay: 0.01) * 0.25
                }
                out[i] = Float(value)
            }
        case .shutter:
            for i in 0..<count {
                let x = t(i)
                var value = 0.0
                for start in [0.0, 0.11] where x >= start {
                    let y = x - start
                    value += noise.next() * env(y, attack: 0.001, decay: 0.018) * (start == 0 ? 0.9 : 0.6)
                }
                out[i] = Float(value)
            }
        }
        // Normalize to −1 dBFS peak.
        let peak = out.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 {
            let gain = 0.89 / peak
            for i in out.indices { out[i] *= gain }
        }
        return out
    }

    /// Writes mono 16-bit PCM WAV.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        let rate = UInt32(sampleRate)
        let byteCount = UInt32(samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))   // PCM
        append(UInt16(1))   // mono
        append(rate)
        append(rate * 2)    // byte rate
        append(UInt16(2))   // block align
        append(UInt16(16))  // bits
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        data.reserveCapacity(data.count + samples.count * 2)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32_767))
        }
        try data.write(to: url, options: .atomic)
    }
}

private extension String {
    /// Stable across launches (Swift's hashValue is randomized per process).
    var hashValueStable: UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}

// MARK: - Library

@MainActor
@Observable
final class SoundEffectsLibrary {
    static let shared = SoundEffectsLibrary()

    private var registry: [String: UUID] = [:]
    private var registryURL: URL { StorageManager.shared.stateDirectory.appendingPathComponent("sfx.json") }
    private var cacheDirectory: URL { StorageManager.shared.cachesDirectory.appendingPathComponent("SFX", isDirectory: true) }

    private init() {
        reload()
    }

    func reload() {
        registry = JSONStore.load([String: UUID].self, from: registryURL) ?? [:]
    }

    /// Cached WAV for previews (rendered on first request, off the main thread).
    func previewURL(for effect: SoundEffect) async throws -> URL {
        let url = cacheDirectory.appendingPathComponent(effect.rawValue + "-v1.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try await Task.detached(priority: .userInitiated) {
            try SoundEffectSynth.writeWAV(SoundEffectSynth.samples(for: effect), to: url)
        }.value
        return url
    }

    /// The media-library asset for an effect (imported once).
    func asset(for effect: SoundEffect, library: MediaLibrary) async throws -> MediaAsset {
        if let id = registry[effect.rawValue], let existing = library.asset(id), !library.isMissing(existing) {
            return existing
        }
        let preview = try await previewURL(for: effect)
        let staged = StorageManager.shared.stagingURL(extension: "wav")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: preview, to: staged)
        let asset = try await library.registerGenerated(file: staged, displayName: "مؤثر - " + effect.title, kind: .audio)
        registry[effect.rawValue] = asset.id
        StorageManager.shared.ensureDirectories()
        try? JSONStore.save(registry, to: registryURL)
        return asset
    }
}
