//
//  StudioViewer.swift
//  ClipStudio — Features/ProStudio
//
//  The program monitor: live GPU preview (same compositor as export), on-canvas
//  transform handles for the selected layer (drag to move, pinch to scale, rotate
//  with two fingers or the rotation handle, corner handles to scale, edge handles
//  to stretch width/height when the aspect lock is off — Part 3), center/edge
//  snapping, safe-area guides, rule-of-thirds grid and the transport bar
//  (J/K/L shuttle, frame steps, edit points, in/out loop, go to timecode).
//

import SwiftUI
import AVFoundation

// MARK: - Geometry

enum ClipGeometry {
    /// Size of a layer on the canvas before its transform (after crop + fit), in canvas pixels.
    static func baseSize(for clip: Clip, asset: MediaAsset?, canvas: CGSize, localTime t: Double) -> CGSize? {
        switch clip.source {
        case .media, .image, .freezeFrame:
            guard let w = asset?.pixelWidth, let h = asset?.pixelHeight, w > 0, h > 0 else { return canvas }
            let crop = clip.crop.value(at: t).clamped()
            let source = CGSize(width: Double(w) * crop.width, height: Double(h) * crop.height)
            return fitted(source, mode: clip.fitMode, canvas: canvas)
        case .solidColor:
            return canvas
        case .text(let content):
            return GeneratedContentRenderer.shared.image(for: .text(content), canvas: canvas, localTime: t,
                                                         clipDuration: clip.duration.seconds)?.extent.size
        case .shape(let content):
            return GeneratedContentRenderer.shared.image(for: .shape(content), canvas: canvas, localTime: t,
                                                         clipDuration: clip.duration.seconds)?.extent.size
        case .sticker(let content):
            return GeneratedContentRenderer.shared.image(for: .sticker(content), canvas: canvas, localTime: t,
                                                         clipDuration: clip.duration.seconds)?.extent.size
        case .adjustment:
            return nil
        }
    }

    static func fitted(_ source: CGSize, mode: FitMode, canvas: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return canvas }
        let sx = canvas.width / source.width
        let sy = canvas.height / source.height
        switch mode {
        case .fit, .fitBlur:
            let s = min(sx, sy)
            return CGSize(width: source.width * s, height: source.height * s)
        case .fill:
            let s = max(sx, sy)
            return CGSize(width: source.width * s, height: source.height * s)
        case .stretch:
            return canvas
        }
    }

    /// Corners of the placed layer (top-left, top-right, bottom-right, bottom-left) in
    /// top-left canvas coordinates, matching LayerRenderer's transform exactly.
    static func corners(for clip: Clip, asset: MediaAsset?, canvas: CGSize, localTime t: Double) -> [CGPoint]? {
        guard let size = baseSize(for: clip, asset: asset, canvas: canvas, localTime: t),
              size.width > 0, size.height > 0 else { return nil }
        let extent = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                            width: size.width, height: size.height)
        let matrix = LayerRenderer.matrix(extent: extent, anchor: clip.transform.anchor,
                                          scale: clip.transform.scale.value(at: t),
                                          stretch: clip.transform.stretch,
                                          rotationDegrees: clip.transform.rotation.value(at: t),
                                          position: clip.transform.position.value(at: t), canvas: canvas)
        let ciCorners = [CGPoint(x: extent.minX, y: extent.maxY), CGPoint(x: extent.maxX, y: extent.maxY),
                         CGPoint(x: extent.maxX, y: extent.minY), CGPoint(x: extent.minX, y: extent.minY)]
        return ciCorners.map { point in
            let mapped = point.applying(matrix)
            return CGPoint(x: mapped.x, y: canvas.height - mapped.y)
        }
    }
}

// MARK: - Viewer

struct StudioViewer: View {
    @Bindable var vm: StudioViewModel
    var compact: Bool
    var onGoTo: () -> Void

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            GeometryReader { geo in
                let container = CGRect(origin: .zero, size: geo.size)
                let videoRect = AVMakeRect(aspectRatio: vm.canvasSize, insideRect: container)
                ZStack {
                    Color.black
                    PlayerSurface(player: vm.player.player)
                    ViewerGuides(rect: videoRect, safe: vm.prefs.showSafeGuides, grid: vm.prefs.showGrid)
                    CanvasOverlay(vm: vm, videoRect: videoRect)
                    statusOverlay
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.stroke))
            ViewerTransport(vm: vm, compact: compact, onGoTo: onGoTo)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if vm.timeline.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "film.stack").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.Palette.accent)
                Text("أضف وسائط للبدء").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.Palette.textPrimary)
                Text("من لوحة الوسائط أو زر +").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        } else if vm.isBuildingPreview && vm.built == nil {
            ProgressView().tint(Theme.Palette.accent)
        }
        if vm.shuttleRate != 0 {
            VStack {
                HStack {
                    Spacer()
                    Text((vm.shuttleRate > 0 ? "▶︎ " : "◀︎ ") + Fmt.number(abs(vm.shuttleRate), digits: 0) + "×")
                        .font(Theme.Typo.mono)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(8)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Guides

struct ViewerGuides: View {
    let rect: CGRect
    let safe: Bool
    let grid: Bool

    var body: some View {
        Canvas { context, _ in
            let stroke = GraphicsContext.Shading.color(.white.opacity(0.35))
            if grid {
                var path = Path()
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                context.stroke(path, with: stroke, lineWidth: 0.7)
            }
            if safe {
                context.stroke(Path(rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05)), with: stroke,
                               style: StrokeStyle(lineWidth: 0.8, dash: [5, 4]))
                context.stroke(Path(rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)), with: stroke,
                               style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                var cross = Path()
                cross.move(to: CGPoint(x: rect.midX - 10, y: rect.midY))
                cross.addLine(to: CGPoint(x: rect.midX + 10, y: rect.midY))
                cross.move(to: CGPoint(x: rect.midX, y: rect.midY - 10))
                cross.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 10))
                context.stroke(cross, with: stroke, lineWidth: 0.8)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Canvas overlay (direct manipulation)

struct CanvasOverlay: View {
    @Bindable var vm: StudioViewModel
    let videoRect: CGRect

    @State private var startPosition: Vec2?
    @State private var startScale: Double?
    @State private var startRotation: Double?
    @State private var cornerStartDistance: CGFloat?
    @State private var snappedCenter = false
    @State private var startStretch: Vec2?
    @State private var edgeStartDistance: CGFloat?

    /// The selected visual clip under the playhead (when it can be edited directly).
    private var editable: (clip: Clip, local: Double)? {
        guard !vm.player.isPlaying, vm.selection.count == 1, let clip = vm.primaryClip, vm.isPlayheadInside(clip),
              let kind = vm.primaryTrackKind, kind.isVisual,
              let track = vm.track(of: clip.id), !track.isLocked, !track.isHidden else { return nil }
        if case .adjustment = clip.source { return nil }
        return (clip, vm.localTime(for: clip))
    }

    private var scaleX: CGFloat { videoRect.width / max(vm.canvasSize.width, 1) }
    private var scaleY: CGFloat { videoRect.height / max(vm.canvasSize.height, 1) }

    private func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: videoRect.minX + point.x * scaleX, y: videoRect.minY + point.y * scaleY)
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.togglePlay() }
            if let target = editable,
               let corners = ClipGeometry.corners(for: target.clip, asset: vm.asset(for: target.clip),
                                                  canvas: vm.canvasSize, localTime: target.local) {
                let points = corners.map(toView)
                manipulationLayer(clip: target.clip, local: target.local, points: points)
            }
        }
    }

    @ViewBuilder
    private func manipulationLayer(clip: Clip, local: Double, points: [CGPoint]) -> some View {
        let center = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
        let topMid = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        let up = CGVector(dx: topMid.x - center.x, dy: topMid.y - center.y)
        let length = max(1, sqrt(up.dx * up.dx + up.dy * up.dy))
        let rotationHandle = CGPoint(x: topMid.x + up.dx / length * 28, y: topMid.y + up.dy / length * 28)

        ZStack {
            Path { path in
                path.addLines(points)
                path.closeSubpath()
            }
            .stroke(Theme.Palette.accent, style: StrokeStyle(lineWidth: 1.5))
            .allowsHitTesting(false)

            if snappedCenter {
                Path { path in
                    path.move(to: CGPoint(x: videoRect.midX, y: videoRect.minY))
                    path.addLine(to: CGPoint(x: videoRect.midX, y: videoRect.maxY))
                    path.move(to: CGPoint(x: videoRect.minX, y: videoRect.midY))
                    path.addLine(to: CGPoint(x: videoRect.maxX, y: videoRect.midY))
                }
                .stroke(Theme.Palette.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
            }

            // Move / pinch / rotate anywhere on the picture.
            Color.clear
                .frame(width: videoRect.width, height: videoRect.height)
                .position(x: videoRect.midX, y: videoRect.midY)
                .contentShape(Rectangle())
                .onTapGesture { vm.togglePlay() }
                .gesture(moveGesture(clip: clip, local: local))
                .simultaneousGesture(scaleGesture(clip: clip, local: local))
                .simultaneousGesture(rotateGesture(clip: clip, local: local))

            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Theme.Palette.textPrimary)
                    .overlay(Circle().strokeBorder(Theme.Palette.accent, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle().inset(by: -10))
                    .position(points[index])
                    .gesture(cornerGesture(clip: clip, local: local, center: center))
                    .accessibilityLabel("مقبض الحجم")
            }

            if !clip.transform.aspectLocked {
                // Edge handles stretch width (left/right) or height (top/bottom) independently.
                ForEach(0..<4, id: \.self) { edge in
                    let a = points[edge], b = points[(edge + 1) % 4]
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.Palette.accent)
                        .frame(width: edge % 2 == 0 ? 22 : 8, height: edge % 2 == 0 ? 8 : 22)
                        .rotationEffect(.degrees(clip.transform.rotation.value(at: local)))
                        .contentShape(Rectangle().inset(by: -12))
                        .position(mid)
                        .gesture(edgeGesture(clip: clip, horizontal: edge % 2 == 1, center: center))
                        .accessibilityLabel(edge % 2 == 1 ? "مقبض العرض" : "مقبض الارتفاع")
                }
            }

            Path { path in
                path.move(to: topMid)
                path.addLine(to: rotationHandle)
            }
            .stroke(Theme.Palette.accent, lineWidth: 1)
            .allowsHitTesting(false)
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.Palette.accent, Theme.Palette.textPrimary)
                .contentShape(Circle().inset(by: -10))
                .position(rotationHandle)
                .gesture(rotationHandleGesture(clip: clip, local: local, center: center))
                .accessibilityLabel("مقبض الدوران")
        }
    }

    // MARK: Gestures

    private func moveGesture(clip: Clip, local: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if startPosition == nil { startPosition = clip.transform.position.value(at: local) }
                guard let start = startPosition else { return }
                var position = Vec2(x: start.x + Double(value.translation.width / max(videoRect.width, 1)),
                                    y: start.y + Double(value.translation.height / max(videoRect.height, 1)))
                var snapped = false
                if abs(position.x - 0.5) < 0.012 { position.x = 0.5; snapped = true }
                if abs(position.y - 0.5) < 0.012 { position.y = 0.5; snapped = true }
                if snapped != snappedCenter {
                    snappedCenter = snapped
                    if snapped { Haptics.selection() }
                }
                let id = clip.id
                vm.updateClip(id, name: "تحريك الطبقة", coalesce: "canvas-move-" + id.uuidString) {
                    $0.transform.position.set(position, at: local)
                }
            }
            .onEnded { _ in
                startPosition = nil
                snappedCenter = false
                vm.endContinuousEdit()
            }
    }

    private func scaleGesture(clip: Clip, local: Double) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if startScale == nil { startScale = clip.transform.scale.value(at: local) }
                let scale = min(max((startScale ?? 1) * Double(value.magnification), 0.02), 20)
                let id = clip.id
                vm.updateClip(id, name: "تغيير الحجم", coalesce: "canvas-scale-" + id.uuidString) {
                    $0.transform.scale.set(scale, at: local)
                }
            }
            .onEnded { _ in
                startScale = nil
                vm.endContinuousEdit()
            }
    }

    private func rotateGesture(clip: Clip, local: Double) -> some Gesture {
        RotateGesture()
            .onChanged { value in
                if startRotation == nil { startRotation = clip.transform.rotation.value(at: local) }
                applyRotation((startRotation ?? 0) + value.rotation.degrees, clip: clip, local: local)
            }
            .onEnded { _ in
                startRotation = nil
                vm.endContinuousEdit()
            }
    }

    /// Stretches one axis (aspect unlocked): width for left/right edges, height for top/bottom.
    private func edgeGesture(clip: Clip, horizontal: Bool, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if startStretch == nil {
                    startStretch = clip.transform.stretch
                    edgeStartDistance = distance(value.startLocation, center)
                }
                let base = startStretch ?? .one
                let factor = Double(distance(value.location, center) / max(edgeStartDistance ?? 1, 1))
                let stretch = horizontal ? Vec2(x: base.x * factor, y: base.y) : Vec2(x: base.x, y: base.y * factor)
                vm.setStretch(stretch, for: clip.id)
            }
            .onEnded { _ in
                startStretch = nil
                edgeStartDistance = nil
                vm.endContinuousEdit()
            }
    }

    private func cornerGesture(clip: Clip, local: Double, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if startScale == nil {
                    startScale = clip.transform.scale.value(at: local)
                    cornerStartDistance = distance(value.startLocation, center)
                }
                let start = max(cornerStartDistance ?? 1, 1)
                let scale = min(max((startScale ?? 1) * Double(distance(value.location, center) / start), 0.02), 20)
                let id = clip.id
                vm.updateClip(id, name: "تغيير الحجم", coalesce: "canvas-scale-" + id.uuidString) {
                    $0.transform.scale.set(scale, at: local)
                }
            }
            .onEnded { _ in
                startScale = nil
                cornerStartDistance = nil
                vm.endContinuousEdit()
            }
    }

    private func rotationHandleGesture(clip: Clip, local: Double, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if startRotation == nil { startRotation = clip.transform.rotation.value(at: local) }
                let a0 = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x)
                let a1 = atan2(value.location.y - center.y, value.location.x - center.x)
                let delta = Double(a1 - a0) * 180 / .pi
                applyRotation((startRotation ?? 0) + delta, clip: clip, local: local)
            }
            .onEnded { _ in
                startRotation = nil
                vm.endContinuousEdit()
            }
    }

    private func applyRotation(_ raw: Double, clip: Clip, local: Double) {
        var degrees = raw
        let nearest = (degrees / 90).rounded() * 90
        if abs(degrees - nearest) < 3 {
            if abs(clip.transform.rotation.value(at: local) - nearest) > 0.01 { Haptics.selection() }
            degrees = nearest
        }
        let id = clip.id
        vm.updateClip(id, name: "دوران", coalesce: "canvas-rotate-" + id.uuidString) {
            $0.transform.rotation.set(degrees, at: local)
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
}

// MARK: - Transport

struct ViewerTransport: View {
    @Bindable var vm: StudioViewModel
    var compact: Bool
    var onGoTo: () -> Void

    var body: some View {
        HStack(spacing: compact ? 10 : 16) {
            Button(action: onGoTo) {
                Text(Fmt.timecode(vm.currentTime, fps: vm.frameRate))
                    .font(compact ? Theme.Typo.mono : Theme.Typo.monoLarge)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("رأس التشغيل")
            .accessibilityValue(Fmt.durationPrecise(vm.currentTime) + " من " + Fmt.durationPrecise(vm.duration))
            .accessibilityHint("اسحب للأعلى أو للأسفل للتقديم أو الإرجاع ثانية، أو انقر مرتين للانتقال إلى توقيت.")
            .accessibilityAdjustableAction { direction in
                // Part 6: VoiceOver users scrub one second per swipe.
                switch direction {
                case .increment: vm.seek(to: vm.currentTime + 1)
                case .decrement: vm.seek(to: vm.currentTime - 1)
                @unknown default: break
                }
            }

            Spacer(minLength: 4)

            if !compact {
                transportButton("backward.end.fill", "النقطة السابقة") { vm.previousEditPoint() }
                transportButton("backward.fill", "تشغيل للخلف (J)") { vm.shuttle(-1) }
            }
            transportButton("backward.frame.fill", "إطار للخلف") { vm.step(frames: -1) }
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 22 : 26, weight: .semibold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.player.isPlaying ? "إيقاف مؤقت" : "تشغيل")
            transportButton("forward.frame.fill", "إطار للأمام") { vm.step(frames: 1) }
            if !compact {
                transportButton("forward.fill", "تشغيل سريع (L)") { vm.shuttle(1) }
                transportButton("forward.end.fill", "النقطة التالية") { vm.nextEditPoint() }
            }

            Spacer(minLength: 4)

            Button { vm.loopsInOut.toggle() } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(vm.loopsInOut ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(vm.inOutRange == nil)
            .accessibilityLabel("تكرار بين نقطتي البداية والنهاية")

            Text(Fmt.duration(vm.duration))
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.horizontal, 6)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func transportButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
