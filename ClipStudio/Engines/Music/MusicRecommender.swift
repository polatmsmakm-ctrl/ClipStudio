//
//  MusicRecommender.swift
//  ClipStudio — Engines/Music (Part 6 suggestions)
//
//  Suggests songs from the user's own media library for a project: the wanted
//  mood (picked, typed, or derived from the project's editing pace) becomes a
//  target tempo and energy; each song's on-device music analysis (BPM, energy
//  curve, length — cached per file) is scored against it. Pure functions; the
//  sheet analyzes songs that have no analysis yet.
//

import Foundation

struct MusicMood: Hashable, Identifiable {
    let id: String
    let title: String
    let bpm: Double
    /// 0…1 average loudness envelope.
    let energy: Double
    let keywords: [String]

    static let all: [MusicMood] = [
        MusicMood(id: "calm", title: "هادئ", bpm: 78, energy: 0.3, keywords: ["هادئ", "هدوء", "calm", "relax", "chill", "استرخاء", "طبيعة"]),
        MusicMood(id: "emotional", title: "عاطفي", bpm: 72, energy: 0.35, keywords: ["عاطفي", "حزين", "رومانسي", "romantic", "sad", "emotional", "ذكريات"]),
        MusicMood(id: "cinematic", title: "سينمائي", bpm: 92, energy: 0.5, keywords: ["سينمائي", "ملحمي", "cinematic", "epic", "وثائقي", "documentary"]),
        MusicMood(id: "happy", title: "مبهج", bpm: 112, energy: 0.6, keywords: ["مبهج", "سعيد", "فرح", "happy", "fun", "عائلة", "رحلة", "travel", "vlog"]),
        MusicMood(id: "energetic", title: "حماسي", bpm: 126, energy: 0.78, keywords: ["حماسي", "حماس", "energetic", "hype", "ريلز", "reels", "تيك توك"]),
        MusicMood(id: "sport", title: "رياضي", bpm: 140, energy: 0.9, keywords: ["رياضي", "رياضة", "sport", "gym", "workout", "سيارات", "سرعة"])
    ]

    static func mood(_ id: String) -> MusicMood? { all.first { $0.id == id } }

    /// Mood named in free text ("إعلان مقهى هادئ" → calm), if any.
    static func detect(in text: String) -> MusicMood? {
        let lower = text.lowercased()
        return all.first { mood in mood.keywords.contains { lower.contains($0.lowercased()) } }
    }

    /// Mood that matches an editing pace (average shot length in seconds).
    static func fromPace(averageShotLength: Double) -> MusicMood {
        switch averageShotLength {
        case ..<1.2: mood("sport")!
        case ..<2: mood("energetic")!
        case ..<3: mood("happy")!
        case ..<4.5: mood("cinematic")!
        default: mood("calm")!
        }
    }
}

struct MusicSuggestion: Identifiable, Hashable {
    let asset: MediaAsset
    let analysis: MusicAnalysis
    let score: Double
    let reasons: [String]

    var id: UUID { asset.id }
}

enum MusicRecommender {
    /// Tempo closeness 0…1 (half / double time count as close — music is felt either way).
    static func tempoMatch(_ bpm: Double, target: Double) -> Double {
        guard bpm > 0, target > 0 else { return 0.3 }
        let candidates = [bpm, bpm * 2, bpm / 2]
        let distance = candidates.map { abs(log2($0 / target)) }.min() ?? 1
        let penalty = candidates.firstIndex { abs(log2($0 / target)) == distance } == 0 ? 0 : 0.1
        return max(0, 1 - distance * 2.2 - penalty)
    }

    static func averageEnergy(_ analysis: MusicAnalysis) -> Double {
        guard !analysis.energy.isEmpty else { return 0.5 }
        return analysis.energy.reduce(0, +) / Double(analysis.energy.count)
    }

    /// 0…100 with Arabic reasons.
    static func score(_ analysis: MusicAnalysis, mood: MusicMood, projectDuration: Double) -> (score: Double, reasons: [String]) {
        var reasons: [String] = []
        let tempo = tempoMatch(analysis.bpm, target: mood.bpm)
        if tempo > 0.75 { reasons.append("سرعة مناسبة (" + Fmt.int(Int(analysis.bpm.rounded())) + " BPM)") }
        let energy = averageEnergy(analysis)
        let energyMatch = max(0, 1 - abs(energy - mood.energy) * 2)
        if energyMatch > 0.7 { reasons.append(energy >= 0.6 ? "طاقة عالية" : energy <= 0.4 ? "طاقة هادئة" : "طاقة متوسطة") }
        var length = 1.0
        if projectDuration > 1 {
            if analysis.duration >= projectDuration {
                reasons.append("تكفي طول الفيديو")
            } else {
                length = max(0.3, analysis.duration / projectDuration)
                reasons.append("أقصر من الفيديو — يمكن تكرار المازورات")
            }
        }
        var bonus = 0.0
        if analysis.dropTime != nil, mood.energy >= 0.6 {
            bonus = 0.05
            reasons.append("فيها ذروة واضحة")
        }
        if analysis.beats.count < 8 {
            reasons.append("إيقاع غير واضح")
        }
        let value = (0.5 * tempo + 0.35 * energyMatch + 0.15 * length + bonus) * (analysis.beats.count < 8 ? 0.8 : 1)
        return (score: min(100, max(0, value * 100)), reasons: reasons)
    }

    static func rank(_ items: [(asset: MediaAsset, analysis: MusicAnalysis)], mood: MusicMood,
                     projectDuration: Double) -> [MusicSuggestion] {
        items.map { item in
            let result = score(item.analysis, mood: mood, projectDuration: projectDuration)
            return MusicSuggestion(asset: item.asset, analysis: item.analysis, score: result.score, reasons: result.reasons)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.asset.displayName < $1.asset.displayName }
    }
}
