//
//  ClipCompositor.swift
//  ClipStudio — Engines/Rendering (VideoProcessingEngine, GPU)
//
//  Custom AVVideoCompositing used for preview playback AND export, so what you
//  see is what you export. Renders with a Metal-backed CIContext.
//  Per frame: background → each visual track bottom→top (transitions resolved
//  inside a track) → blended with the clip's blend mode → adjustment layers →
//  project watermark (Part 3).
//

import Foundation
import AVFoundation
import CoreImage
import Metal

final class ClipCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "com.rashid.clipstudio.compositor", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "com.rashid.clipstudio.compositor.state")
    private var shouldCancel = false
    private let ciContext: CIContext
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    enum CompositorError: Error {
        case noOutputBuffer
    }

    override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "ClipCompositor"])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        super.init()
    }

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            if self.stateQueue.sync(execute: { self.shouldCancel }) {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                do {
                    let buffer = try self.render(request)
                    request.finish(withComposedVideoFrame: buffer)
                } catch {
                    request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateQueue.sync { shouldCancel = true }
        renderQueue.async { [weak self] in
            self?.stateQueue.sync { self?.shouldCancel = false }
        }
    }

    // MARK: Rendering

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let output = request.renderContext.newPixelBuffer() else { throw CompositorError.noOutputBuffer }
        let size = request.renderContext.size
        let canvasRect = CGRect(origin: .zero, size: size)
        let time = request.compositionTime

        guard let instruction = request.videoCompositionInstruction as? RenderInstruction else {
            ciContext.render(CIImage(color: .black).cropped(to: canvasRect), to: output, bounds: canvasRect, colorSpace: outputColorSpace)
            return output
        }

        var canvas = CIImage(color: instruction.backgroundColor.ciColor).cropped(to: canvasRect)

        for track in instruction.layers {
            let active = track.entries.filter { $0.isActive(at: time) }
            guard !active.isEmpty else { continue }

            if track.kind == .adjustment {
                for entry in active {
                    canvas = LayerRenderer.applyAdjustment(clip: entry.clip, to: canvas,
                                                           localTime: entry.localTime(at: time), canvas: size)
                }
                continue
            }

            var rendered: [(entry: LayerEntry, image: CIImage)] = []
            for entry in active {
                guard let source = sourceImage(for: entry, request: request, time: time, canvasRect: canvasRect) else { continue }
                let role: LayerRole
                switch entry.source {
                case .track, .still: role = .media
                case .generated: role = .generated
                case .solid: role = .solid
                case .adjustment: continue
                }
                let image = LayerRenderer.render(source: source, clip: entry.clip, role: role,
                                                 localTime: entry.localTime(at: time),
                                                 clipDuration: entry.duration.seconds, canvas: size)
                rendered.append((entry, image))
            }
            guard !rendered.isEmpty else { continue }

            if rendered.count >= 2,
               let incoming = rendered.last,
               let transition = incoming.entry.clip.transitionIn,
               transition.kind != .none,
               transition.duration.seconds > 0 {
                let outgoing = rendered[rendered.count - 2]
                let progress = CMTimeSubtract(time, incoming.entry.start).seconds / transition.duration.seconds
                let combined = TransitionRenderer.blend(from: outgoing.image, to: incoming.image,
                                                        progress: progress, kind: transition.kind, canvas: canvasRect)
                for earlier in rendered.dropLast(2) {
                    canvas = BlendRenderer.composite(earlier.image, over: canvas, mode: earlier.entry.clip.blendMode)
                }
                canvas = BlendRenderer.composite(combined, over: canvas, mode: incoming.entry.clip.blendMode)
            } else {
                for item in rendered {
                    canvas = BlendRenderer.composite(item.image, over: canvas, mode: item.entry.clip.blendMode)
                }
            }
            canvas = canvas.cropped(to: canvasRect)
        }

        if let watermark = instruction.watermark {
            canvas = WatermarkRenderer.composite(watermark, over: canvas, canvas: size)
        }

        ciContext.render(canvas, to: output, bounds: canvasRect, colorSpace: outputColorSpace)
        return output
    }

    private func sourceImage(for entry: LayerEntry, request: AVAsynchronousVideoCompositionRequest,
                             time: CMTime, canvasRect: CGRect) -> CIImage? {
        switch entry.source {
        case .track(let trackID, let orientation):
            guard let buffer = request.sourceFrame(byTrackID: trackID) else { return nil }
            let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        case .still(let image):
            return image
        case .generated(let content):
            return GeneratedContentRenderer.shared.image(for: content, canvas: canvasRect.size,
                                                         localTime: entry.localTime(at: time),
                                                         clipDuration: entry.duration.seconds)
        case .solid(let color):
            return CIImage(color: color.ciColor).cropped(to: canvasRect)
        case .adjustment:
            return nil
        }
    }
}
