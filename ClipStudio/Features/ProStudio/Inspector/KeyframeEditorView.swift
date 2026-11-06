//
//  KeyframeEditorView.swift
//  ClipStudio — Features/ProStudio/Inspector
//
//  Keyframe editor for one clip: a lane per animated property (and per animated
//  effect) across the clip's duration with the playhead. Tap a keyframe to select
//  it, drag it to retime, then choose its easing (linear, ease in/out, smooth,
//  hold), jump to it, or delete it. Missing lanes can be animated with one tap.
//

import SwiftUI

struct KeyframeEditorView: View {
    let vm: StudioViewModel
    let clipID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var selected: KeyframeMark?
    @State private var dragOffset: Double?

    private var clip: Clip? { TimelineEngine.clip(clipID, in: vm.timeline) }

    var body: some View {
        NavigationStack {
            Group {
                if let clip {
                    ScrollView {
                        VStack(spacing: 14) {
                            lanes(clip)
                            if let mark = selected, let fresh = refreshed(mark, in: clip) {
                                selectedPanel(fresh, clip: clip)
                            } else {
                                Text("اضغط على إطار مفتاحي لتعديل انسيابيته أو اسحبه لتغيير توقيته.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            addSection(clip)
                        }
                        .padding(14)
                    }
                } else {
                    EmptyStateView(systemImage: "diamond", title: "المقطع غير موجود", message: "ربما حُذف المقطع.")
                }
            }
            .screenBackground()
            .navigationTitle("الإطارات المفتاحية")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { vm.jumpToKeyframe(next: false) } label: { Image(systemName: "chevron.backward.2") }
                    Spacer()
                    Text(Fmt.timecode(vm.currentTime, fps: vm.frameRate)).font(Theme.Typo.mono)
                    Spacer()
                    Button { vm.jumpToKeyframe(next: true) } label: { Image(systemName: "chevron.forward.2") }
                }
            }
        }
    }

    private struct Lane: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let marks: [KeyframeMark]
    }

    private func laneList(_ clip: Clip) -> [Lane] {
        var lanes: [Lane] = KeyframeProperty.allCases.compactMap { property in
            guard clip.isAnimated(property) else { return nil }
            return Lane(id: property.rawValue, title: property.title, symbol: property.symbol, marks: clip.keyframeMarks(property))
        }
        for effect in clip.effects where effect.intensity.isAnimated {
            lanes.append(Lane(id: effect.id.uuidString, title: effect.kind.title, symbol: effect.kind.symbol,
                              marks: clip.effectKeyframeMarks(effect.id)))
        }
        return lanes
    }

    private func refreshed(_ mark: KeyframeMark, in clip: Clip) -> KeyframeMark? {
        laneList(clip).flatMap(\.marks).first { $0.id == mark.id }
    }

    @ViewBuilder
    private func lanes(_ clip: Clip) -> some View {
        let lanes = laneList(clip)
        if lanes.isEmpty {
            EmptyStateView(systemImage: "diamond", title: "لا توجد حركة بعد",
                           message: "أضف إطارًا مفتاحيًا لأي خاصية من الأسفل أو من زر ◆ في المفتش.")
        } else {
            VStack(spacing: 8) {
                ForEach(lanes) { lane in
                    HStack(spacing: 8) {
                        Label(lane.title, systemImage: lane.symbol)
                            .font(.caption.weight(.semibold))
                            .frame(width: 104, alignment: .leading)
                            .lineLimit(1)
                        laneTrack(lane, clip: clip)
                            .frame(height: 34)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Palette.surfaceRaised))
        }
    }

    private func laneTrack(_ lane: Lane, clip: Clip) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(clip.duration.seconds, 0.001)
            let playheadX = CGFloat((vm.currentTime - clip.start.seconds) / duration) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.surfaceHighlight).frame(height: 4)
                if playheadX >= 0 && playheadX <= width {
                    Rectangle().fill(Theme.Palette.accent.opacity(0.6)).frame(width: 1.5).offset(x: playheadX)
                }
                ForEach(lane.marks) { mark in
                    let isSelected = selected?.id == mark.id
                    let time = isSelected && dragOffset != nil ? min(max(mark.time + (dragOffset ?? 0), 0), duration) : mark.time
                    Image(systemName: mark.easing == .hold ? "square.fill" : "diamond.fill")
                        .font(.system(size: isSelected ? 18 : 14))
                        .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.textPrimary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                        .offset(x: CGFloat(time / duration) * width - 15)
                        .onTapGesture {
                            selected = mark
                            Haptics.selection()
                        }
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    selected = mark
                                    dragOffset = Double(value.translation.width / max(width, 1)) * duration
                                }
                                .onEnded { value in
                                    let delta = Double(value.translation.width / max(width, 1)) * duration
                                    let target = (min(max(mark.time + delta, 0), duration) * vm.frameRate).rounded() / vm.frameRate
                                    dragOffset = nil
                                    vm.updateClip(clipID, name: "توقيت الإطار المفتاحي") { $0.moveKeyframe(mark, to: target) }
                                }
                        )
                        .accessibilityLabel("إطار مفتاحي " + lane.title + " " + Fmt.durationPrecise(mark.time))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func selectedPanel(_ mark: KeyframeMark, clip: Clip) -> some View {
        InspectorSection(title: "الإطار المحدد", systemImage: "diamond.fill") {
            HStack {
                Text("الوقت داخل المقطع").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(Fmt.durationPrecise(mark.time)).font(Theme.Typo.mono)
            }
            Text("الانسيابية حتى الإطار التالي").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                ForEach(Easing.allCases, id: \.self) { easing in
                    ChipButton(title: easing.title, isSelected: mark.easing == easing) {
                        vm.updateClip(clipID, name: "انسيابية") { $0.setEasing(mark, easing) }
                    }
                }
            }
            EasingCurve(easing: mark.easing)
                .frame(height: 70)
            HStack(spacing: 10) {
                Button {
                    vm.seek(to: clip.start.seconds + mark.time)
                } label: { Label("اذهب إليه", systemImage: "scope") }
                    .buttonStyle(.bordered)
                Spacer()
                Button(role: .destructive) {
                    vm.updateClip(clipID, name: "حذف إطار مفتاحي") { $0.removeKeyframe(mark) }
                    selected = nil
                } label: { Label("حذف", systemImage: "trash") }
                    .buttonStyle(.bordered)
            }
            .font(.caption)
        }
    }

    private func addSection(_ clip: Clip) -> some View {
        InspectorSection(title: "تحريك خاصية عند رأس التشغيل", systemImage: "plus.diamond") {
            if !vm.isPlayheadInside(clip) {
                Text("ضع رأس التشغيل داخل المقطع أولاً.").font(.caption).foregroundStyle(Theme.Palette.warning)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(KeyframeProperty.allCases) { property in
                    Button {
                        vm.toggleKeyframe(property, clipID: clipID)
                    } label: {
                        Label(property.title, systemImage: vm.hasKeyframe(property, clip: clip) ? "diamond.fill" : property.symbol)
                            .font(.caption)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.isPlayheadInside(clip))
                }
            }
        }
    }
}

/// Visual preview of an easing curve.
struct EasingCurve: View {
    let easing: Easing

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let steps = 40
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let value = easing == .hold ? (i == steps ? 1 : 0) : easing.apply(t)
                let point = CGPoint(x: CGFloat(t) * size.width, y: size.height - CGFloat(value) * size.height)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Theme.Palette.accent), lineWidth: 2)
            context.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.Palette.stroke), lineWidth: 1)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}
