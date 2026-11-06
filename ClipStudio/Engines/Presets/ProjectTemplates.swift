//
//  ProjectTemplates.swift
//  ClipStudio — Engines/Presets
//
//  Ready-made Pro Studio project setups: canvas, frame rate and an organized,
//  color-coded track layout (main video, B-roll, titles, captions, voice, music,
//  effects). The slideshow template also adds crossfades and gentle motion to
//  the chosen photos.
//

import Foundation

struct TemplateTrack: Hashable {
    let kind: TrackKind
    let name: String
    let color: RGBAColor
    /// Where imported audio files go (music bed).
    var receivesAudio = false
}

enum ProjectTemplate: String, CaseIterable, Identifiable {
    case blank, reels, youtube, square, portrait, podcast, slideshow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "فارغ"
        case .reels: "ريلز / تيك توك"
        case .youtube: "يوتيوب"
        case .square: "منشور مربع"
        case .portrait: "منشور 4:5"
        case .podcast: "بودكاست"
        case .slideshow: "عرض صور"
        }
    }

    var subtitle: String {
        switch self {
        case .blank: "مسار فيديو وطبقة علوية وصوت"
        case .reels: "9:16 • نصوص وترجمة وتعليق صوتي وموسيقى"
        case .youtube: "16:9 • لقطات إضافية وعناوين وترجمة وموسيقى"
        case .square: "1:1 • فيديو ونصوص وموسيقى"
        case .portrait: "4:5 • فيديو ونصوص وموسيقى"
        case .podcast: "16:9 • كاميرتان ومتحدثان وترجمة"
        case .slideshow: "16:9 • انتقالات وحركة هادئة للصور"
        }
    }

    var symbol: String {
        switch self {
        case .blank: "doc"
        case .reels: "rectangle.portrait"
        case .youtube: "play.rectangle"
        case .square: "square"
        case .portrait: "rectangle.portrait.and.arrow.forward"
        case .podcast: "mic"
        case .slideshow: "photo.stack"
        }
    }

    var aspect: AspectRatio? {
        switch self {
        case .blank: nil
        case .reels: .portrait9x16
        case .youtube, .podcast, .slideshow: .landscape16x9
        case .square: .square
        case .portrait: .portrait4x5
        }
    }

    private static let blue = RGBAColor(hex: 0x5B8DEF)
    private static let purple = RGBAColor(hex: 0xB07CE8)
    private static let gold = RGBAColor(hex: 0xE3B04B)
    private static let teal = RGBAColor(hex: 0x4FB3A9)
    private static let green = RGBAColor(hex: 0x5FC48F)
    private static let orange = RGBAColor(hex: 0xE58F4A)
    private static let red = RGBAColor(hex: 0xE25C55)

    /// Tracks bottom → top for visual tracks; audio tracks follow.
    var tracks: [TemplateTrack] {
        switch self {
        case .blank:
            return [TemplateTrack(kind: .video, name: "فيديو 1", color: Self.blue),
                    TemplateTrack(kind: .overlay, name: "طبقة علوية 1", color: Self.purple),
                    TemplateTrack(kind: .audio, name: "صوت 1", color: Self.green, receivesAudio: true)]
        case .reels:
            return [TemplateTrack(kind: .video, name: "الفيديو الرئيسي", color: Self.blue),
                    TemplateTrack(kind: .overlay, name: "لقطات إضافية", color: Self.purple),
                    TemplateTrack(kind: .text, name: "النصوص", color: Self.gold),
                    TemplateTrack(kind: .subtitle, name: "الترجمة", color: Self.orange),
                    TemplateTrack(kind: .audio, name: "التعليق الصوتي", color: Self.teal),
                    TemplateTrack(kind: .audio, name: "الموسيقى", color: Self.green, receivesAudio: true),
                    TemplateTrack(kind: .audio, name: "المؤثرات", color: Self.red)]
        case .youtube:
            return [TemplateTrack(kind: .video, name: "الفيديو الرئيسي", color: Self.blue),
                    TemplateTrack(kind: .overlay, name: "لقطات إضافية", color: Self.purple),
                    TemplateTrack(kind: .overlay, name: "الشعار والرسومات", color: Self.purple),
                    TemplateTrack(kind: .text, name: "العناوين", color: Self.gold),
                    TemplateTrack(kind: .subtitle, name: "الترجمة", color: Self.orange),
                    TemplateTrack(kind: .audio, name: "الحوار", color: Self.teal),
                    TemplateTrack(kind: .audio, name: "الموسيقى", color: Self.green, receivesAudio: true),
                    TemplateTrack(kind: .audio, name: "المؤثرات", color: Self.red)]
        case .square, .portrait:
            return [TemplateTrack(kind: .video, name: "الفيديو", color: Self.blue),
                    TemplateTrack(kind: .overlay, name: "طبقة علوية", color: Self.purple),
                    TemplateTrack(kind: .text, name: "النصوص", color: Self.gold),
                    TemplateTrack(kind: .audio, name: "الموسيقى", color: Self.green, receivesAudio: true)]
        case .podcast:
            return [TemplateTrack(kind: .video, name: "الكاميرا 1", color: Self.blue),
                    TemplateTrack(kind: .overlay, name: "الكاميرا 2", color: Self.purple),
                    TemplateTrack(kind: .text, name: "الأسماء", color: Self.gold),
                    TemplateTrack(kind: .subtitle, name: "الترجمة", color: Self.orange),
                    TemplateTrack(kind: .audio, name: "المتحدث 1", color: Self.teal),
                    TemplateTrack(kind: .audio, name: "المتحدث 2", color: Self.teal),
                    TemplateTrack(kind: .audio, name: "موسيقى المقدمة", color: Self.green, receivesAudio: true)]
        case .slideshow:
            return [TemplateTrack(kind: .video, name: "الصور", color: Self.blue),
                    TemplateTrack(kind: .text, name: "العناوين", color: Self.gold),
                    TemplateTrack(kind: .audio, name: "الموسيقى", color: Self.green, receivesAudio: true)]
        }
    }

    /// Builds the empty, organized timeline.
    func makeTimeline() -> Timeline {
        Timeline(tracks: tracks.map { spec in
            var track = Track(kind: spec.kind, name: spec.name)
            track.color = spec.color
            return track
        })
    }

    /// Index of the track that receives imported audio.
    func audioTrackIndex(in timeline: Timeline) -> Int? {
        let specs = tracks
        if let index = specs.firstIndex(where: \.receivesAudio), timeline.tracks.indices.contains(index) { return index }
        return timeline.tracks.firstIndex { $0.kind == .audio }
    }

    /// Slideshows add a crossfade between photos and alternate gentle motion.
    var addsSlideshowMotion: Bool { self == .slideshow }
}
