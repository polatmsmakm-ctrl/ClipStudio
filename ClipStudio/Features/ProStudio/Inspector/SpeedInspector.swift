//
//  SpeedInspector.swift
//  ClipStudio — Features/ProStudio/Inspector
//
//  Constant speed (slow motion → 16×) with presets, speed-ramp curve editor
//  (drag points, tap to add, long-press to delete, ramp presets), pitch
//  preservation, reverse playback (renders a reversed copy once, with progress)
//  and freeze frames.
//

import SwiftUI

struct SpeedInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var rampDraft: [SpeedRampPoint]?
    @State private var draggingIndex: Int?

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    private static let presets: [Double] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 4, 8]

    var body: some View {
        if let clip = editor.clip {
            if clip.sourceRange == nil || clip.mediaAssetID == nil {
                InspectorSection(title: "السرعة", systemImage: "gauge.with.dots.needle.67percent") {
                    Text("تغيير السرعة متاح لمقاطع الفيديو والصوت.").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            } else {
                VStack(spacing: 12) {
                    constantSection(clip)
                    rampSection(clip)
                    if vm.primaryTrackKind?.isVisual == true {
                        reverseSection(clip)
                    }
                }
            }
        }
    }

    // MARK: Constant

    private func constantSection(_ clip: Clip) -> some View {
        InspectorSection(title: "سرعة ثابتة", systemImage: "gauge.with.dots.needle.67percent") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
                ForEach(Self.presets, id: \.self) { rate in
                    ChipButton(title: Fmt.number(rate, digits: rate < 1 && rate != 0.5 ? 2 : (rate < 1 ? 1 : 0)) + "×",
                               isSelected: clip.speed.ramp.isEmpty && abs(clip.speed.rate - rate) < 0.001) {
                        vm.setRate(rate, for: clipID)
                    }
                }
            }
            PrecisionSlider(title: "السرعة", value: Binding(get: { clip.speed.ramp.isEmpty ? clip.speed.rate : 1 }, set: { value in
                vm.setRate(value, for: clipID, coalesce: "rate-" + clipID.uuidString)
            }), range: 0.1...8, defaultValue: 1, step: 0.05,
                            format: { Fmt.number($0, digits: 2) + "×" }, onEditingChanged: editor.editingChanged)
            HStack {
                StatBadge(title: "المدة على الخط", value: Fmt.durationPrecise(clip.duration.seconds), systemImage: "clock")
                StatBadge(title: "من المصدر", value: Fmt.durationPrecise(clip.sourceRange?.duration.seconds ?? 0), systemImage: "film")
            }
            Toggle(isOn: Binding(get: { clip.speed.preservePitch }, set: { vm.setPreservePitch($0, for: clipID) })) {
                Label("الحفاظ على طبقة الصوت", systemImage: "waveform.path")
            }
            .tint(Theme.Palette.accent)
            Text("تغيير السرعة يزيح المقاطع التالية في نفس المسار حتى لا تتداخل.")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    // MARK: Ramp

    private func rampSection(_ clip: Clip) -> some View {
        let points = rampDraft ?? (clip.speed.ramp.isEmpty ? [] : clip.speed.ramp.sorted { $0.position < $1.position })
        return InspectorSection(title: "منحنى السرعة", systemImage: "point.3.connected.trianglepath.dotted") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    rampPreset("مونتاج", [(0, 1), (0.3, 3), (0.5, 0.4), (0.7, 3), (1, 1)])
                    rampPreset("بطولي", [(0, 1.5), (0.4, 1), (0.5, 0.25), (0.6, 1), (1, 1.5)])
                    rampPreset("طلقة", [(0, 2), (0.45, 2), (0.5, 0.2), (0.75, 0.2), (1, 2)])
                    rampPreset("تسارع", [(0, 0.5), (1, 3)])
                    rampPreset("تباطؤ", [(0, 3), (1, 0.5)])
                    rampPreset("نبض", [(0, 1), (0.25, 2.5), (0.5, 0.5), (0.75, 2.5), (1, 1)])
                }
            }
            RampGraph(points: points, draggingIndex: $draggingIndex,
                      onChange: { updated in rampDraft = updated },
                      onCommit: { updated in
                          rampDraft = nil
                          vm.setRamp(updated, for: clipID)
                          vm.endContinuousEdit()
                      })
                .frame(height: 170)
            HStack {
                if !clip.speed.ramp.isEmpty {
                    Button(role: .destructive) {
                        vm.setRate(1, for: clipID)
                    } label: { Label("إزالة المنحنى", systemImage: "xmark") }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        vm.setRamp([SpeedRampPoint(position: 0, rate: 1), SpeedRampPoint(position: 1, rate: 1)], for: clipID)
                    } label: { Label("إنشاء منحنى", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .font(.caption)
            Text("اسحب النقاط لتغيير السرعة، اضغط على المنحنى لإضافة نقطة، واضغط مطولاً على نقطة لحذفها. المقاطع ذات المنحنى لا يمكن إطالتها بالقص.")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func rampPreset(_ title: String, _ values: [(Double, Double)]) -> some View {
        ChipButton(title: title, isSelected: false) {
            vm.setRamp(values.map { SpeedRampPoint(position: $0.0, rate: $0.1) }, for: clipID)
        }
    }

    // MARK: Reverse & freeze

    private func reverseSection(_ clip: Clip) -> some View {
        InspectorSection(title: "عكس وتجميد", systemImage: "arrow.uturn.backward") {
            Button {
                vm.toggleReverse(clipID: clipID)
            } label: {
                Label(clip.speed.isReversed ? "إلغاء العكس" : "تشغيل المقطع بالعكس", systemImage: "arrow.uturn.backward.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.csSecondary)
            if !clip.speed.isReversed && clip.speed.reversedAssetID == nil {
                Text("أول مرة يُنشأ نسخة معكوسة من الفيديو على جهازك (مع الصوت) — قد يستغرق ذلك بعض الوقت حسب طول الملف.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            DecimalField(title: "مدة الإطار الثابت", value: Binding(get: { vm.prefs.defaultFreezeDuration },
                                                                   set: { vm.prefs.defaultFreezeDuration = $0 }),
                         range: 0.2...30, step: 0.5, digits: 1, unit: "ث")
            Button {
                vm.select(clipID)
                vm.insertFreezeFrame()
            } label: {
                Label("إدراج إطار ثابت عند رأس التشغيل", systemImage: "pause.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.csSecondary)
            .disabled(!vm.isPlayheadInside(clip))
        }
    }
}

// MARK: - Ramp graph

struct RampGraph: View {
    let points: [SpeedRampPoint]
    @Binding var draggingIndex: Int?
    let onChange: ([SpeedRampPoint]) -> Void
    let onCommit: ([SpeedRampPoint]) -> Void

    private static let minRate = 0.1
    private static let maxRate = 8.0

    private func y(for rate: Double, height: CGFloat) -> CGFloat {
        let t = (log(max(rate, Self.minRate)) - log(Self.minRate)) / (log(Self.maxRate) - log(Self.minRate))
        return height - CGFloat(t) * height
    }

    private func rate(for y: CGFloat, height: CGFloat) -> Double {
        let t = Double(1 - min(max(y / max(height, 1), 0), 1))
        return exp(log(Self.minRate) + t * (log(Self.maxRate) - log(Self.minRate)))
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.surfaceHighlight.opacity(0.7))
                Canvas { context, canvasSize in
                    for rate in [0.25, 0.5, 1.0, 2.0, 4.0] {
                        let yy = y(for: rate, height: canvasSize.height)
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: yy))
                        line.addLine(to: CGPoint(x: canvasSize.width, y: yy))
                        context.stroke(line, with: .color(rate == 1 ? Theme.Palette.textTertiary : Theme.Palette.stroke),
                                       style: StrokeStyle(lineWidth: 1, dash: rate == 1 ? [] : [3, 3]))
                        context.draw(Text(Fmt.number(rate, digits: rate < 1 ? 2 : 0) + "×")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary),
                                     at: CGPoint(x: 4, y: yy - 6), anchor: .leading)
                    }
                    let sorted = points.sorted { $0.position < $1.position }
                    if sorted.count >= 2 {
                        var curve = Path()
                        for (index, point) in sorted.enumerated() {
                            let p = CGPoint(x: CGFloat(point.position) * canvasSize.width, y: y(for: point.rate, height: canvasSize.height))
                            if index == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                        }
                        context.stroke(curve, with: .color(Theme.Palette.accent), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        guard !points.isEmpty else { return }
                        var updated = points
                        updated.append(SpeedRampPoint(position: Double(min(max(value.location.x / max(size.width, 1), 0), 1)),
                                                      rate: rate(for: value.location.y, height: size.height)))
                        onCommit(updated.sorted { $0.position < $1.position })
                    }
                )
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(draggingIndex == index ? Theme.Palette.accent : Theme.Palette.textPrimary)
                        .overlay(Circle().strokeBorder(Theme.Palette.accent, lineWidth: 2))
                        .frame(width: 18, height: 18)
                        .contentShape(Circle().inset(by: -10))
                        .position(x: CGFloat(point.position) * size.width, y: y(for: point.rate, height: size.height))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    draggingIndex = index
                                    var updated = points
                                    let isEdge = index == 0 || index == points.count - 1
                                    let position = isEdge ? point.position : Double(min(max(value.location.x / max(size.width, 1), 0.01), 0.99))
                                    updated[index] = SpeedRampPoint(position: position, rate: rate(for: value.location.y, height: size.height))
                                    onChange(updated)
                                }
                                .onEnded { _ in
                                    draggingIndex = nil
                                    onCommit(points.sorted { $0.position < $1.position })
                                }
                        )
                        .onLongPressGesture(minimumDuration: 0.5) {
                            guard points.count > 2, index != 0, index != points.count - 1 else { return }
                            var updated = points
                            updated.remove(at: index)
                            Haptics.warning()
                            onCommit(updated)
                        }
                        .accessibilityLabel("نقطة سرعة " + Fmt.number(point.rate, digits: 2) + "×")
                }
                if points.isEmpty {
                    Text("لا يوجد منحنى — اختر قالبًا أو أنشئ منحنى")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}
