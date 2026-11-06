//
//  VolumeAutomationOverlay.swift
//  ClipStudio — Features/AudioStudio (Part 3)
//
//  The volume line drawn over audio clips when "volume automation" is on:
//  tap the line area to add a point, drag a point (time + level), double-tap a
//  point to delete it, drag the level handle to change the whole clip when it has
//  no points. Each drag is one undo step.
//

import SwiftUI

struct VolumeAutomationOverlay: View {
    let vm: StudioViewModel
    let clip: Clip
    /// Distance from the clip start to the drawn region (points).
    let contentOffset: CGFloat
    let width: CGFloat
    let height: CGFloat

    @State private var baseDragStart: Double?

    private var inset: CGFloat { 5 }
    private var usable: CGFloat { max(4, height - inset * 2) }
    private var pps: Double { vm.pixelsPerSecond }

    private func x(_ local: Double) -> CGFloat { CGFloat(local * pps) - contentOffset }
    private func local(_ x: CGFloat) -> Double { Double(x + contentOffset) / pps }
    private func y(_ value: Double) -> CGFloat { inset + CGFloat(1 - min(max(value, 0), 1)) * usable }
    private func value(_ y: CGFloat) -> Double { Double(1 - (y - inset) / usable) }

    var body: some View {
        let volume = clip.audio.volume
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    let t = local(tap.location.x)
                    vm.addVolumeKeyframe(clipID: clip.id, at: t, value: value(tap.location.y))
                })
            Canvas { context, size in
                var path = Path()
                let step: CGFloat = 4
                var px: CGFloat = 0
                var first = true
                while px <= size.width + step {
                    let t = min(max(0, local(px)), clip.duration.seconds)
                    let point = CGPoint(x: px, y: y(volume.value(at: t)))
                    if first { path.move(to: point); first = false } else { path.addLine(to: point) }
                    px += step
                }
                context.stroke(path, with: .color(Theme.Palette.accent), lineWidth: 2)
            }
            .allowsHitTesting(false)
            if volume.keyframes.isEmpty {
                Capsule()
                    .fill(Theme.Palette.accent)
                    .frame(width: 26, height: 10)
                    .position(x: min(max(18, width / 2), width - 18), y: y(volume.base))
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            if baseDragStart == nil { baseDragStart = volume.base }
                            let start = baseDragStart ?? volume.base
                            vm.setBaseVolume(clipID: clip.id, value: start - Double(drag.translation.height / usable))
                        }
                        .onEnded { _ in
                            baseDragStart = nil
                            vm.endContinuousEdit()
                        })
                    .accessibilityLabel("مستوى الصوت " + Fmt.number(volume.base * 100, digits: 0) + "%")
            }
            ForEach(volume.keyframes) { key in
                let kx = x(key.time)
                if kx >= -8 && kx <= width + 8 {
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Theme.Palette.accent, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .contentShape(Circle().inset(by: -8))
                        .position(x: kx, y: y(key.value))
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                vm.moveVolumeKeyframe(clipID: clip.id, keyframeID: key.id,
                                                      time: local(drag.location.x), value: value(drag.location.y))
                            }
                            .onEnded { _ in vm.endContinuousEdit() })
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            vm.removeVolumeKeyframe(clipID: clip.id, keyframeID: key.id)
                        })
                        .accessibilityLabel("نقطة مستوى " + Fmt.number(key.value * 100, digits: 0) + "%")
                }
            }
        }
        .frame(width: width, height: height)
        .environment(\.layoutDirection, .leftToRight)
    }
}
