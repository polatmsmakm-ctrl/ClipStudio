//
//  RenderTypes.swift
//  ClipStudio — Engines/Rendering (EditingEngine)
//
//  Immutable render instructions consumed by ClipCompositor on its render queue.
//  One instruction per time interval in which the set of active layers is constant.
//

import Foundation
import AVFoundation
import CoreImage

enum GeneratedContent: Hashable {
    case text(TextContent)
    case shape(ShapeContent)
    case sticker(StickerContent)
}

enum ResolvedSource {
    /// Frames come from a composition video track; orientation fixes rotated phone video.
    case track(CMPersistentTrackID, CGImagePropertyOrientation)
    /// Pre-decoded still (image file or freeze frame).
    case still(CIImage)
    case generated(GeneratedContent)
    case solid(RGBAColor)
    case adjustment
}

struct LayerEntry {
    let clip: Clip
    let source: ResolvedSource
    let start: CMTime
    let duration: CMTime

    var end: CMTime { CMTimeAdd(start, duration) }

    func localTime(at time: CMTime) -> Double {
        max(0, CMTimeSubtract(time, start).seconds)
    }

    func isActive(at time: CMTime) -> Bool {
        CMTimeCompare(time, start) >= 0 && CMTimeCompare(time, end) < 0
    }
}

struct TrackLayer {
    let kind: TrackKind
    let entries: [LayerEntry]
}

final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let layers: [TrackLayer]
    let backgroundColor: RGBAColor
    /// Project watermark drawn over the finished frame (Part 3).
    let watermark: ResolvedWatermark?

    init(timeRange: CMTimeRange, sourceTrackIDs: [CMPersistentTrackID], layers: [TrackLayer], backgroundColor: RGBAColor,
         watermark: ResolvedWatermark? = nil) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = Array(Set(sourceTrackIDs)).sorted().map { NSNumber(value: $0) }
        self.layers = layers
        self.backgroundColor = backgroundColor
        self.watermark = watermark
        super.init()
    }
}

enum CMTimeMath {
    static func max(_ a: CMTime, _ b: CMTime) -> CMTime { CMTimeCompare(a, b) >= 0 ? a : b }
    static func min(_ a: CMTime, _ b: CMTime) -> CMTime { CMTimeCompare(a, b) <= 0 ? a : b }
    static func isLess(_ a: CMTime, _ b: CMTime) -> Bool { CMTimeCompare(a, b) < 0 }
}
