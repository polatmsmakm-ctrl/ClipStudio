//
//  OutputVariants.swift
//  ClipStudio — Engines/Intelligence (Part 4)
//
//  One edit → several deliverables. Builds a copy of a project for another aspect
//  ratio (9:16, 16:9, 1:1, 4:5):
//  • full-frame pictures are reframed — smart (crop keyframes that follow the
//    subject from a Vision track), centred crop, or whole picture over blur;
//  • picture-in-picture layers keep their relative placement;
//  • titles and stickers are resized for the new shape and kept in the safe area;
//  • captions are re-wrapped for the new line length.
//  The source project is never modified; each variant is a new project.
//

import Foundation
import CoreGraphics

struct VariantOptions: Hashable {
    var method: ReframeMethod = .smart
    /// Seconds — larger = calmer virtual camera.
    var smoothing: Double = 0.8
}

struct VariantReport: Hashable {
    var reframed = 0
    var smart = 0
    var texts = 0
    var captions = 0
}

enum OutputVariants {

    static func settings(from settings: ProjectSettings, format: OutputFormat) -> ProjectSettings {
        let short = min(settings.canvasWidth, settings.canvasHeight)
        var result = ProjectSettings(aspect: format.aspect, shortSide: short, frameRate: settings.frameRate)
        result.backgroundColor = settings.backgroundColor
        result.watermark = settings.watermark
        return result
    }

    /// Whether a picture clip fills the frame (main footage) rather than being a placed layer.
    static func isFullFrame(_ clip: Clip) -> Bool {
        let t = clip.transform
        return abs(t.scale.base - 1) < 0.02 && t.scale.keyframes.isEmpty && t.position.keyframes.isEmpty
            && abs(t.position.base.x - 0.5) < 0.02 && abs(t.position.base.y - 0.5) < 0.02
            && clip.crop.keyframes.isEmpty && clip.fitMode != .stretch
    }

    /// Centred crop (normalized, inside `region`) that has `targetAspect` in source pixels.
    static func centeredCrop(in region: RectValue, sourceWidth: Double, sourceHeight: Double, targetAspect: Double) -> RectValue {
        let regionAspect = (region.width * sourceWidth) / max(1, region.height * sourceHeight)
        var width = region.width, height = region.height
        if regionAspect > targetAspect {
            width = region.width * targetAspect / regionAspect
        } else {
            height = region.height * regionAspect / targetAspect
        }
        return RectValue(x: region.x + (region.width - width) / 2, y: region.y + (region.height - height) / 2,
                         width: width, height: height)
    }

    /// The variant project (new id, same media) for `format`.
    static func makeVariant(of project: EditProject, format: OutputFormat, options: VariantOptions,
                            assets: [UUID: MediaAsset], subjectTrack: (Clip) -> SubjectTrack?,
                            report: inout VariantReport) -> EditProject {
        var variant = project
        variant.id = UUID()
        variant.name = project.name + " — " + format.title
        variant.createdAt = Date()
        variant.modifiedAt = Date()
        variant.settings = settings(from: project.settings, format: format)
        variant.studio = StudioState()
        let oldCanvas = project.settings.canvasSize
        let newCanvas = variant.settings.canvasSize
        variant.timeline = adapt(project.timeline, from: oldCanvas, to: newCanvas, settings: variant.settings,
                                 options: options, assets: assets, subjectTrack: subjectTrack, report: &report)
        for index in variant.compounds.indices {
            variant.compounds[index].timeline = adapt(variant.compounds[index].timeline, from: oldCanvas, to: newCanvas,
                                                      settings: variant.settings, options: options, assets: assets,
                                                      subjectTrack: subjectTrack, report: &report)
            variant.compounds[index].needsRender = true
        }
        return variant
    }

    static func adapt(_ timeline: Timeline, from oldCanvas: CGSize, to newCanvas: CGSize, settings: ProjectSettings,
                      options: VariantOptions, assets: [UUID: MediaAsset], subjectTrack: (Clip) -> SubjectTrack?,
                      report: inout VariantReport) -> Timeline {
        var result = timeline
        let oldAspect = Double(oldCanvas.width / max(1, oldCanvas.height))
        let newAspect = Double(newCanvas.width / max(1, newCanvas.height))
        let textFactor = min(1.6, max(0.55, sqrt(newAspect / max(0.01, oldAspect))))
        let layout = CaptionLayoutOptions.defaults(for: settings)

        for t in result.tracks.indices {
            for c in result.tracks[t].clips.indices {
                var clip = result.tracks[t].clips[c]
                switch clip.source {
                case .media(let id), .image(let id), .freezeFrame(let id, _):
                    guard result.tracks[t].kind.isVisual, isFullFrame(clip), let asset = assets[id],
                          let w = asset.pixelWidth, let h = asset.pixelHeight, w > 0, h > 0 else { break }
                    let region = clip.crop.base.clamped()
                    switch options.method {
                    case .fitBlur:
                        clip.fitMode = .fitBlur
                    case .center:
                        clip.crop = KeyframedValue(centeredCrop(in: region, sourceWidth: Double(w), sourceHeight: Double(h),
                                                                targetAspect: newAspect))
                        clip.fitMode = .fill
                    case .smart:
                        if case .media = clip.source, region.isFull, let track = subjectTrack(clip), track.coverage > 0.2 {
                            clip.crop = ReframeEngine.cropKeyframes(for: clip, track: track, targetAspect: newAspect,
                                                                    smoothing: options.smoothing)
                            report.smart += 1
                        } else {
                            clip.crop = KeyframedValue(centeredCrop(in: region, sourceWidth: Double(w), sourceHeight: Double(h),
                                                                    targetAspect: newAspect))
                        }
                        clip.fitMode = .fill
                    }
                    report.reframed += 1
                case .text(var content):
                    content.style.sizeRatio = min(0.3, max(0.012, content.style.sizeRatio * textFactor))
                    if var caption = content.caption {
                        let words = caption.words.map(\.text)
                        let breaks = Set(CaptionBuilder.lineBreaks(words, maxChars: layout.maxCharsPerLine, maxLines: layout.maxLines))
                        for index in caption.words.indices { caption.words[index].breaksLine = breaks.contains(index) }
                        content.caption = caption
                        content.text = caption.composedText
                        report.captions += 1
                    } else {
                        report.texts += 1
                    }
                    clip.source = .text(content)
                    if !clip.transform.position.isAnimated { QualityInspector.moveIntoSafeArea(&clip, canvas: newCanvas) }
                case .sticker(var content):
                    content.sizeRatio = min(0.8, max(0.03, content.sizeRatio * textFactor))
                    clip.source = .sticker(content)
                    if !clip.transform.position.isAnimated { QualityInspector.moveIntoSafeArea(&clip, canvas: newCanvas) }
                default:
                    break
                }
                result.tracks[t].clips[c] = clip
            }
        }
        return result
    }
}
