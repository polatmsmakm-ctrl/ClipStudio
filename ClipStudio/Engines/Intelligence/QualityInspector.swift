//
//  QualityInspector.swift
//  ClipStudio — Engines/Intelligence (Part 4)
//
//  Pre-export quality check. Fast checks are pure functions of the project:
//  missing media, black gaps, flash frames, low resolution, frame-rate mismatch,
//  text outside the title-safe area or too small, caption reading speed and
//  overlaps, hidden / muted tracks, disabled clips, risky gain, broken watermark.
//  The deep scan measures real loudness (BS.1770) and exposure of each clip.
//  Most issues carry a one-tap fix that is applied as a normal (undoable) edit.
//

import Foundation
import CoreGraphics
import CoreImage
import CoreMedia

enum QualitySeverity: Int, Comparable, Hashable {
    case info, warning, problem

    static func < (lhs: QualitySeverity, rhs: QualitySeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .info: "ملاحظة"
        case .warning: "تنبيه"
        case .problem: "مشكلة"
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .problem: "xmark.octagon"
        }
    }
}

enum QualityCategory: String, CaseIterable, Hashable {
    case media, picture, text, captions, audio, structure

    var title: String {
        switch self {
        case .media: "الملفات"
        case .picture: "الصورة"
        case .text: "النصوص"
        case .captions: "الترجمة"
        case .audio: "الصوت"
        case .structure: "الخط الزمني"
        }
    }

    var symbol: String {
        switch self {
        case .media: "folder.badge.questionmark"
        case .picture: "photo"
        case .text: "textformat"
        case .captions: "captions.bubble"
        case .audio: "speaker.wave.2"
        case .structure: "timeline.selection"
        }
    }
}

enum QualityFix: Hashable {
    case replaceMedia(UUID)
    case closeGap(start: Double, end: Double)
    case removeClip(UUID)
    case moveIntoSafeArea(UUID)
    case enlargeText(UUID)
    case showTrack(UUID)
    case unmuteTrack(UUID)
    case enableClip(UUID)
    case enableLimiter(UUID)
    case normalize([UUID])
    case setColor(UUID, ColorAdjustments)
    case setWatermark

    var title: String {
        switch self {
        case .replaceMedia: "استبدال الملف"
        case .closeGap: "إغلاق الفراغ"
        case .removeClip: "حذف المقطع"
        case .moveIntoSafeArea: "نقل داخل المنطقة الآمنة"
        case .enlargeText: "تكبير النص"
        case .showTrack: "إظهار المسار"
        case .unmuteTrack: "تشغيل صوت المسار"
        case .enableClip: "تفعيل المقطع"
        case .enableLimiter: "تفعيل المحدِّد"
        case .normalize: "تسوية مستوى الصوت"
        case .setColor: "تصحيح الإضاءة"
        case .setWatermark: "إعداد العلامة المائية"
        }
    }
}

struct QualityIssue: Identifiable, Hashable {
    var id = UUID()
    var severity: QualitySeverity
    var category: QualityCategory
    var title: String
    var detail: String
    /// Timeline seconds to jump to.
    var time: Double?
    var clipID: UUID?
    var fix: QualityFix?
}

struct QualityInput {
    var timeline: Timeline
    var settings: ProjectSettings
    var assets: [UUID: MediaAsset]
    var missing: Set<UUID>
}

enum QualityInspector {
    static let safeMargin = 0.05
    static let minimumTextSize = 0.022
    static let maximumCaptionSpeed = 20.0

    // MARK: Fast checks

    static func inspect(_ input: QualityInput) -> [QualityIssue] {
        let timeline = input.timeline
        let canvas = input.settings.canvasSize
        let fps = Double(max(1, input.settings.frameRate))
        let frame = 1 / fps
        var issues: [QualityIssue] = []

        guard !timeline.isEmpty else {
            return [QualityIssue(severity: .info, category: .structure, title: "الخط الزمني فارغ",
                                 detail: "أضف مقاطع أولاً.", time: nil, clipID: nil, fix: nil)]
        }

        var reportedMissing: Set<UUID> = []
        var reportedFPS: Set<UUID> = []

        for track in timeline.tracks {
            if !track.clips.isEmpty, track.isHidden, track.kind.isVisual {
                issues.append(QualityIssue(severity: .warning, category: .structure, title: "مسار مخفي: " + track.name,
                                           detail: "مقاطعه لن تظهر في التصدير.", time: track.clips.first?.start.seconds,
                                           clipID: nil, fix: .showTrack(track.id)))
            }
            if !track.clips.isEmpty, track.isMuted, track.carriesAudio {
                issues.append(QualityIssue(severity: .info, category: .audio, title: "مسار مكتوم: " + track.name,
                                           detail: "صوت هذا المسار لن يُسمع في التصدير.", time: track.clips.first?.start.seconds,
                                           clipID: nil, fix: .unmuteTrack(track.id)))
            }
            for clip in track.clips {
                let mid = clip.start.seconds + clip.duration.seconds / 2
                // Missing files.
                for id in clip.referencedAssetIDs where input.missing.contains(id) || input.assets[id] == nil {
                    guard !reportedMissing.contains(clip.id) else { continue }
                    reportedMissing.insert(clip.id)
                    issues.append(QualityIssue(severity: .problem, category: .media, title: "ملف مفقود: " + clip.name,
                                               detail: "الملف الأصلي غير موجود — سيظهر فراغ أسود أو صمت.",
                                               time: clip.start.seconds, clipID: clip.id, fix: .replaceMedia(clip.id)))
                }
                if !clip.isEnabled {
                    issues.append(QualityIssue(severity: .info, category: .structure, title: "مقطع معطّل: " + clip.name,
                                               detail: "لن يظهر في التصدير.", time: clip.start.seconds, clipID: clip.id,
                                               fix: .enableClip(clip.id)))
                    continue
                }
                // Flash frames.
                if track.kind.isVisual, clip.duration.seconds < frame * 3 - 1e-6 {
                    issues.append(QualityIssue(severity: .problem, category: .structure, title: "إطار وامض",
                                               detail: "مقطع مدته " + Fmt.int(Int((clip.duration.seconds * fps).rounded()))
                                                   + " إطار فقط — غالبًا بقايا قص.",
                                               time: clip.start.seconds, clipID: clip.id, fix: .removeClip(clip.id)))
                }
                switch clip.source {
                case .media(let id), .image(let id), .freezeFrame(let id, _):
                    guard track.kind.isVisual, let asset = input.assets[id] else { break }
                    if let ratio = upscaleRatio(clip: clip, asset: asset, canvas: canvas), ratio > 1.5 {
                        issues.append(QualityIssue(severity: .warning, category: .picture, title: "دقة منخفضة: " + clip.name,
                                                   detail: "الصورة مكبرة " + Fmt.number(ratio, digits: 1)
                                                       + "× فوق دقتها الأصلية وقد تبدو ضبابية.",
                                                   time: mid, clipID: clip.id, fix: nil))
                    }
                    if case .media = clip.source, asset.kind == .video, let assetFPS = asset.frameRate, assetFPS > 1,
                       !reportedFPS.contains(id) {
                        let ratio = assetFPS / fps
                        let mismatched = ratio < 0.97 || abs(ratio - ratio.rounded()) > 0.04
                        if mismatched, clip.speed.isNormal {
                            reportedFPS.insert(id)
                            issues.append(QualityIssue(severity: .info, category: .picture, title: "معدل إطارات مختلف",
                                                       detail: asset.displayName + " بمعدل " + Fmt.fps(assetFPS)
                                                           + " والمشروع " + Fmt.fps(fps) + " — قد تظهر الحركة متقطعة قليلًا.",
                                                       time: clip.start.seconds, clipID: clip.id, fix: nil))
                        }
                    }
                case .text(let content):
                    let scale = clip.transform.scale.value(at: clip.duration.seconds / 2)
                    if content.style.sizeRatio * scale < minimumTextSize {
                        issues.append(QualityIssue(severity: .warning, category: .text, title: "نص صغير جدًا",
                                                   detail: "«" + String(content.text.prefix(24)) + "» قد لا يُقرأ على الجوال.",
                                                   time: mid, clipID: clip.id, fix: .enlargeText(clip.id)))
                    }
                    if let caption = content.caption {
                        let letters = caption.composedText.filter { !$0.isWhitespace }.count
                        let speed = Double(letters) / max(0.1, clip.duration.seconds)
                        if speed > maximumCaptionSpeed {
                            issues.append(QualityIssue(severity: .warning, category: .captions, title: "ترجمة سريعة",
                                                       detail: Fmt.number(speed) + " حرف/ث — يصعب قراءتها (الأفضل أقل من "
                                                           + Fmt.number(maximumCaptionSpeed) + ").",
                                                       time: clip.start.seconds, clipID: clip.id, fix: nil))
                        }
                    }
                    if let issue = safeAreaIssue(clip: clip, canvas: canvas) { issues.append(issue) }
                case .sticker, .shape:
                    if let issue = safeAreaIssue(clip: clip, canvas: canvas) { issues.append(issue) }
                default:
                    break
                }
                // Gain.
                if track.carriesAudio, clip.audio.effects.gainDB > 12, !clip.audio.effects.limiter, !clip.audio.isMuted {
                    issues.append(QualityIssue(severity: .warning, category: .audio, title: "تضخيم عالٍ: " + clip.name,
                                               detail: "+" + Fmt.number(clip.audio.effects.gainDB, digits: 1)
                                                   + " dB بدون محدِّد — قد يحدث تشويش.",
                                               time: clip.start.seconds, clipID: clip.id, fix: .enableLimiter(clip.id)))
                }
            }
        }

        issues += gapIssues(timeline, frame: frame)
        issues += captionOverlapIssues(timeline)

        if let watermark = input.settings.watermark, watermark.isEnabled {
            if watermark.kind == .image, let id = watermark.imageAssetID, input.missing.contains(id) || input.assets[id] == nil {
                issues.append(QualityIssue(severity: .warning, category: .media, title: "شعار العلامة المائية مفقود",
                                           detail: "لن تظهر العلامة المائية.", time: nil, clipID: nil, fix: .setWatermark))
            } else if !watermark.isDrawable {
                issues.append(QualityIssue(severity: .info, category: .picture, title: "العلامة المائية فارغة",
                                           detail: "العلامة مفعّلة لكن بدون نص أو شعار.", time: nil, clipID: nil, fix: .setWatermark))
            }
        }
        return sorted(issues)
    }

    static func sorted(_ issues: [QualityIssue]) -> [QualityIssue] {
        issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return ($0.time ?? -1) < ($1.time ?? -1)
        }
    }

    /// How much the clip's picture is enlarged beyond its native pixels on the canvas.
    static func upscaleRatio(clip: Clip, asset: MediaAsset, canvas: CGSize) -> Double? {
        guard let w = asset.pixelWidth, let h = asset.pixelHeight, w > 0, h > 0 else { return nil }
        let crop = clip.crop.base.clamped()
        let source = CGSize(width: Double(w) * crop.width, height: Double(h) * crop.height)
        let fitted = ClipGeometry.fitted(source, mode: clip.fitMode == .stretch ? .fill : clip.fitMode, canvas: canvas)
        let scale = max(clip.transform.scale.base, clip.transform.scale.keyframes.map(\.value).max() ?? 0)
        let displayed = Double(fitted.width) * scale
        return displayed / Double(source.width)
    }

    /// Bounding box of a layer in canvas points (top-left origin) at its midpoint.
    static func bounds(of clip: Clip, canvas: CGSize) -> CGRect? {
        guard let corners = ClipGeometry.corners(for: clip, asset: nil, canvas: canvas, localTime: clip.duration.seconds / 2),
              corners.count == 4 else { return nil }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func safeRect(_ canvas: CGSize) -> CGRect {
        CGRect(x: canvas.width * safeMargin, y: canvas.height * safeMargin,
               width: canvas.width * (1 - 2 * safeMargin), height: canvas.height * (1 - 2 * safeMargin))
    }

    private static func safeAreaIssue(clip: Clip, canvas: CGSize) -> QualityIssue? {
        guard !clip.transform.position.isAnimated, let box = bounds(of: clip, canvas: canvas) else { return nil }
        let safe = safeRect(canvas).insetBy(dx: -1, dy: -1)
        guard !safe.contains(box), box.intersects(CGRect(origin: .zero, size: canvas)) else { return nil }
        return QualityIssue(severity: .warning, category: .text, title: "خارج المنطقة الآمنة: " + clip.name,
                            detail: "قد يُقص عند العرض أو تغطيه أزرار التطبيقات.",
                            time: clip.start.seconds + clip.duration.seconds / 2, clipID: clip.id,
                            fix: .moveIntoSafeArea(clip.id))
    }

    /// Times where no picture layer is visible (black frames) between 0 and the end.
    static func gapIssues(_ timeline: Timeline, frame: Double) -> [QualityIssue] {
        var spans: [(Double, Double)] = []
        for track in timeline.tracks where track.kind == .video || track.kind == .overlay {
            guard !track.isHidden else { continue }
            for clip in track.clips where clip.isEnabled {
                switch clip.source {
                case .media, .image, .freezeFrame, .solidColor:
                    spans.append((clip.start.seconds, clip.end.seconds))
                default:
                    continue
                }
            }
        }
        let end = timeline.tracks.filter { $0.kind.isVisual }.map(\.endTime.seconds).max() ?? 0
        guard !spans.isEmpty, end > 0 else { return [] }
        spans.sort { $0.0 < $1.0 }
        var gaps: [(Double, Double)] = []
        var cursor = 0.0
        for span in spans {
            if span.0 > cursor + frame * 0.5 { gaps.append((cursor, span.0)) }
            cursor = max(cursor, span.1)
        }
        if end > cursor + frame * 0.5 { gaps.append((cursor, end)) }
        return gaps.map { gap in
            QualityIssue(severity: gap.1 - gap.0 > 0.5 ? .problem : .warning, category: .picture, title: "فراغ أسود",
                         detail: "من " + Fmt.timecode(gap.0, fps: 1 / frame) + " إلى " + Fmt.timecode(gap.1, fps: 1 / frame)
                             + " لا توجد صورة.",
                         time: gap.0, clipID: nil, fix: .closeGap(start: gap.0, end: gap.1))
        }
    }

    static func captionOverlapIssues(_ timeline: Timeline) -> [QualityIssue] {
        var captions: [Clip] = []
        for track in timeline.tracks where !track.isHidden {
            for clip in track.clips where clip.isEnabled {
                if case .text(let content) = clip.source, content.isCaption { captions.append(clip) }
            }
        }
        captions.sort { $0.start < $1.start }
        var issues: [QualityIssue] = []
        guard captions.count > 1 else { return [] }
        for index in 1..<captions.count {
            let a = captions[index - 1], b = captions[index]
            if b.start.seconds < a.end.seconds - 0.05 {
                issues.append(QualityIssue(severity: .warning, category: .captions, title: "ترجمتان في نفس الوقت",
                                           detail: "تتداخل الترجمة مع السابقة وقد تظهران فوق بعض.",
                                           time: b.start.seconds, clipID: b.id, fix: nil))
            }
        }
        return issues
    }

    // MARK: Fixes (pure)

    /// Applies a fix that only touches the timeline. Returns false when the fix needs the UI
    /// (replace media, normalization, watermark settings).
    @discardableResult
    static func apply(_ fix: QualityFix, to timeline: inout Timeline, canvas: CGSize, context: EditContext) -> Bool {
        switch fix {
        case .closeGap(let start, let end):
            let length = context.snap(end - start)
            guard length > 0 else { return false }
            for t in timeline.tracks.indices where !timeline.tracks[t].isLocked {
                TimelineEngine.shiftClips(&timeline, track: t, startingAt: end - context.tolerance, by: -length, context: context)
            }
            TimelineEngine.finalize(&timeline, context: context)
            return true
        case .removeClip(let id):
            try? TimelineEngine.delete([id], ripple: false, in: &timeline, context: context)
            return true
        case .moveIntoSafeArea(let id):
            guard let ref = TimelineEngine.locate(id, in: timeline) else { return false }
            var clip = timeline.tracks[ref.track].clips[ref.index]
            moveIntoSafeArea(&clip, canvas: canvas)
            timeline.tracks[ref.track].clips[ref.index] = clip
            return true
        case .enlargeText(let id):
            TimelineEngine.updateClips([id], in: &timeline) { clip in
                guard case .text(var content) = clip.source else { return }
                let scale = max(0.05, clip.transform.scale.value(at: clip.duration.seconds / 2))
                content.style.sizeRatio = max(content.style.sizeRatio, 0.032 / scale)
                clip.source = .text(content)
            }
            return true
        case .showTrack(let id):
            guard let index = timeline.tracks.firstIndex(where: { $0.id == id }) else { return false }
            timeline.tracks[index].isHidden = false
            return true
        case .unmuteTrack(let id):
            guard let index = timeline.tracks.firstIndex(where: { $0.id == id }) else { return false }
            timeline.tracks[index].isMuted = false
            return true
        case .enableClip(let id):
            TimelineEngine.updateClips([id], in: &timeline) { $0.isEnabled = true }
            return true
        case .enableLimiter(let id):
            TimelineEngine.updateClips([id], in: &timeline) { $0.audio.effects.limiter = true }
            return true
        case .setColor(let id, let color):
            TimelineEngine.updateClips([id], in: &timeline) { $0.color = color }
            return true
        case .replaceMedia, .normalize, .setWatermark:
            return false
        }
    }

    /// Moves (and if needed shrinks) a layer so its box sits in the title-safe area.
    static func moveIntoSafeArea(_ clip: inout Clip, canvas: CGSize) {
        guard let box = bounds(of: clip, canvas: canvas) else { return }
        let safe = safeRect(canvas)
        var scaleFactor = 1.0
        if box.width > safe.width || box.height > safe.height {
            scaleFactor = Double(min(safe.width / max(1, box.width), safe.height / max(1, box.height))) * 0.98
        }
        let width = box.width * CGFloat(scaleFactor), height = box.height * CGFloat(scaleFactor)
        let center = CGPoint(x: box.midX, y: box.midY)
        let targetX = min(max(center.x, safe.minX + width / 2), safe.maxX - width / 2)
        let targetY = min(max(center.y, safe.minY + height / 2), safe.maxY - height / 2)
        let dx = Double((targetX - center.x) / canvas.width)
        let dy = Double((targetY - center.y) / canvas.height)
        clip.transform.position.base.x += dx
        clip.transform.position.base.y += dy
        for index in clip.transform.position.keyframes.indices {
            clip.transform.position.keyframes[index].value.x += dx
            clip.transform.position.keyframes[index].value.y += dy
        }
        if scaleFactor < 1 {
            clip.transform.scale.base *= scaleFactor
            for index in clip.transform.scale.keyframes.indices { clip.transform.scale.keyframes[index].value *= scaleFactor }
        }
    }

    // MARK: Deep scan

    /// Loudness (per sound clip) and exposure (per picture clip) measured on the real media.
    static func deepScan(_ input: QualityInput, media: MediaURLMap, control: RenderControl?,
                         progress: @Sendable (Double) -> Void) async -> [QualityIssue] {
        var issues: [QualityIssue] = []
        var soundJobs: [(Clip, URL, CMTimeRange)] = []
        var pictureJobs: [Clip] = []
        for track in input.timeline.tracks {
            for clip in track.clips where clip.isEnabled {
                switch clip.source {
                case .media(let id):
                    if track.carriesAudio, !track.isMuted, !clip.audio.isMuted, let asset = input.assets[id],
                       asset.kind == .audio || asset.hasAudio, let url = media[id], let range = clip.sourceRange {
                        soundJobs.append((clip, url, range.cm))
                    }
                    if track.kind.isVisual, !track.isHidden, input.assets[id]?.kind == .video { pictureJobs.append(clip) }
                case .image, .freezeFrame:
                    if track.kind.isVisual, !track.isHidden { pictureJobs.append(clip) }
                default:
                    break
                }
            }
        }
        let total = Double(max(1, soundJobs.count + pictureJobs.count))
        var done = 0.0
        for (clip, url, range) in soundJobs {
            if control?.isCancelled == true || Task.isCancelled { break }
            if let result = try? await LoudnessAnalyzer.measure(url: url, range: range, control: control), !result.isSilent {
                let loudness = result.integrated + clip.audio.effects.gainDB
                if loudness > -8 {
                    issues.append(QualityIssue(severity: .warning, category: .audio, title: "صوت عالٍ جدًا: " + clip.name,
                                               detail: Fmt.number(loudness, digits: 1) + " LUFS — قد يتشوّه أو يُخفّض في المنصات.",
                                               time: clip.start.seconds, clipID: clip.id, fix: .normalize([clip.id])))
                } else if loudness < -30 {
                    issues.append(QualityIssue(severity: .warning, category: .audio, title: "صوت منخفض جدًا: " + clip.name,
                                               detail: Fmt.number(loudness, digits: 1) + " LUFS — بالكاد يُسمع.",
                                               time: clip.start.seconds, clipID: clip.id, fix: .normalize([clip.id])))
                }
                if result.peak + clip.audio.effects.gainDB > -0.3, !clip.audio.effects.limiter {
                    issues.append(QualityIssue(severity: .problem, category: .audio, title: "تشويش (تجاوز الذروة): " + clip.name,
                                               detail: "الذروة تتجاوز 0 dBFS بدون محدِّد.", time: clip.start.seconds,
                                               clipID: clip.id, fix: .enableLimiter(clip.id)))
                }
            }
            done += 1
            progress(done / total)
        }
        let canvas = input.settings.canvasSize
        for clip in pictureJobs {
            if control?.isCancelled == true || Task.isCancelled { break }
            let middle = clip.duration.seconds / 2
            if let frame = await FramePreviewRenderer.shared.sourceFrame(for: clip, localTime: middle, media: media,
                                                                       canvas: canvas, maxDimension: 256) {
                let graded = FramePreviewRenderer.shared.graded(frame, color: clip.color, lut: clip.lut)
                if let stats = FramePreviewRenderer.shared.statistics(graded) {
                    if let fix = exposureFix(clip: clip, luma: stats.lumaMean) {
                        let dark = stats.lumaMean < 0.5
                        issues.append(QualityIssue(severity: .warning, category: .picture,
                                                   title: (dark ? "لقطة مظلمة: " : "لقطة ساطعة جدًا: ") + clip.name,
                                                   detail: "متوسط الإضاءة " + Fmt.percent(stats.lumaMean) + ".",
                                                   time: clip.start.seconds + middle, clipID: clip.id, fix: fix))
                    }
                }
            }
            done += 1
            progress(done / total)
        }
        return sorted(issues)
    }

    /// Exposure correction toward mid-grey for frames that are clearly too dark or bright.
    static func exposureFix(clip: Clip, luma: Double) -> QualityFix? {
        guard luma < 0.12 || luma > 0.88 else { return nil }
        let ev = min(1.5, max(-1.5, log2(0.42 / max(0.02, luma))))
        var color = clip.color
        color.exposure = min(100, max(-100, color.exposure + ev * 50 * 0.6))
        return .setColor(clip.id, color)
    }
}
