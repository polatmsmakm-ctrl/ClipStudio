//
//  AudioEffects.swift
//  ClipStudio — Models (Audio Studio, Part 3)
//
//  Per-clip audio processing settings: gain (boost above 100%), balance, high-pass,
//  5-band parametric EQ, spectral noise reduction, compressor, voice enhancement
//  and a safety limiter. Processed in real time by Engines/Audio (MTAudioProcessingTap)
//  for preview and export alike. Old project files decode with neutral settings.
//

import Foundation

struct EQBand: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case lowShelf, peak, highShelf
    }

    var id: Int
    var kind: Kind
    /// Hz.
    var frequency: Double
    /// −15…+15 dB.
    var gainDB: Double
    var q: Double

    static let defaults: [EQBand] = [
        EQBand(id: 0, kind: .lowShelf, frequency: 100, gainDB: 0, q: 0.707),
        EQBand(id: 1, kind: .peak, frequency: 300, gainDB: 0, q: 1.0),
        EQBand(id: 2, kind: .peak, frequency: 1_000, gainDB: 0, q: 1.0),
        EQBand(id: 3, kind: .peak, frequency: 3_500, gainDB: 0, q: 1.0),
        EQBand(id: 4, kind: .highShelf, frequency: 9_000, gainDB: 0, q: 0.707)
    ]

    var title: String {
        switch id {
        case 0: "الجهير"
        case 1: "المنخفض المتوسط"
        case 2: "المتوسط"
        case 3: "الحضور"
        default: "الحدة"
        }
    }

    /// Frequency range the band can be tuned in.
    var frequencyRange: ClosedRange<Double> {
        switch id {
        case 0: 30...400
        case 1: 120...1_200
        case 2: 400...4_000
        case 3: 1_500...8_000
        default: 4_000...16_000
        }
    }
}

struct CompressorSettings: Codable, Hashable {
    var thresholdDB: Double = -20
    var ratio: Double = 3
    var attackMS: Double = 10
    var releaseMS: Double = 150
    var makeupDB: Double = 3
}

struct AudioEffects: Codable, Hashable {
    /// −24…+24 dB, applied by the processor (so boosts above 100% are possible).
    var gainDB: Double = 0
    /// −1 (left) … +1 (right) balance.
    var pan: Double = 0
    /// 0 = off, otherwise the cutoff in Hz (20…400).
    var highPassHz: Double = 0
    var eqEnabled = false
    var eq: [EQBand] = EQBand.defaults
    /// 0…1 strength of the adaptive spectral noise reduction.
    var noiseReduction: Double = 0
    var compressorEnabled = false
    var compressor = CompressorSettings()
    /// Voice clarity chain: rumble cut, de-mud, presence, air and gentle compression.
    var voiceEnhance = false
    /// Peak limiter at −1 dBFS (prevents clipping when boosting).
    var limiter = true

    init() {}

    var hasActiveEQ: Bool { eqEnabled && eq.contains { abs($0.gainDB) > 0.05 } }

    /// True when processing would not change the sound (the processor is bypassed).
    var isNeutral: Bool {
        abs(gainDB) < 0.01 && abs(pan) < 0.001 && highPassHz < 1 && !hasActiveEQ
            && noiseReduction < 0.001 && !compressorEnabled && !voiceEnhance
    }

    /// Short names of the active processors (timeline badge / inspector summary).
    var activeNames: [String] {
        var names: [String] = []
        if abs(gainDB) >= 0.01 { names.append((gainDB > 0 ? "+" : "") + Fmt.number(gainDB, digits: 1) + " dB") }
        if highPassHz >= 1 { names.append("قطع منخفض") }
        if hasActiveEQ { names.append("معادل") }
        if noiseReduction >= 0.001 { names.append("إزالة ضوضاء") }
        if compressorEnabled { names.append("ضاغط") }
        if voiceEnhance { names.append("تحسين الصوت") }
        if abs(pan) >= 0.001 { names.append("توازن") }
        return names
    }

    var gainLinear: Double { pow(10, gainDB / 20) }

    enum CodingKeys: String, CodingKey {
        case gainDB, pan, highPassHz, eqEnabled, eq, noiseReduction, compressorEnabled, compressor, voiceEnhance, limiter
    }
}

extension AudioEffects {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        gainDB = c.value(.gainDB, default: 0.0)
        pan = c.value(.pan, default: 0.0)
        highPassHz = c.value(.highPassHz, default: 0.0)
        eqEnabled = c.value(.eqEnabled, default: false)
        let bands = c.value(.eq, default: EQBand.defaults)
        eq = bands.count == EQBand.defaults.count ? bands : EQBand.defaults
        noiseReduction = c.value(.noiseReduction, default: 0.0)
        compressorEnabled = c.value(.compressorEnabled, default: false)
        compressor = c.value(.compressor, default: CompressorSettings())
        voiceEnhance = c.value(.voiceEnhance, default: false)
        limiter = c.value(.limiter, default: true)
    }
}

extension ClipAudio {
    /// The audio attributes that need an AVAudioMix rebuild (effects update live).
    var mixSignature: ClipAudio {
        var copy = self
        copy.effects = AudioEffects()
        return copy
    }
}

// MARK: - Presets

enum AudioEffectPreset: String, CaseIterable, Identifiable {
    case voiceClear, podcast, noiseCleanup, backgroundMusic, telephone, warm, reset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voiceClear: "صوت واضح"
        case .podcast: "بودكاست"
        case .noiseCleanup: "تنظيف الضوضاء"
        case .backgroundMusic: "موسيقى خلفية"
        case .telephone: "هاتف / راديو"
        case .warm: "دافئ وعميق"
        case .reset: "بدون معالجة"
        }
    }

    var symbol: String {
        switch self {
        case .voiceClear: "person.wave.2"
        case .podcast: "mic"
        case .noiseCleanup: "wind"
        case .backgroundMusic: "music.note"
        case .telephone: "phone"
        case .warm: "flame"
        case .reset: "arrow.counterclockwise"
        }
    }

    func apply(to effects: inout AudioEffects) {
        let pan = effects.pan
        var result = AudioEffects()
        result.pan = pan
        switch self {
        case .voiceClear:
            result.highPassHz = 80
            result.voiceEnhance = true
            result.noiseReduction = 0.35
        case .podcast:
            result.highPassHz = 70
            result.voiceEnhance = true
            result.noiseReduction = 0.25
            result.compressorEnabled = true
            result.compressor = CompressorSettings(thresholdDB: -22, ratio: 4, attackMS: 6, releaseMS: 140, makeupDB: 6)
        case .noiseCleanup:
            result.highPassHz = 60
            result.noiseReduction = 0.7
        case .backgroundMusic:
            result.gainDB = -6
            result.eqEnabled = true
            result.eq = EQBand.defaults
            result.eq[2].gainDB = -3
            result.eq[3].gainDB = -2
        case .telephone:
            result.highPassHz = 320
            result.eqEnabled = true
            result.eq = EQBand.defaults
            result.eq[2].gainDB = 5
            result.eq[4].gainDB = -15
            result.compressorEnabled = true
            result.compressor = CompressorSettings(thresholdDB: -26, ratio: 6, attackMS: 3, releaseMS: 90, makeupDB: 6)
        case .warm:
            result.eqEnabled = true
            result.eq = EQBand.defaults
            result.eq[0].gainDB = 4
            result.eq[1].gainDB = 1.5
            result.eq[4].gainDB = -2.5
        case .reset:
            break
        }
        effects = result
    }
}
