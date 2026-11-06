//
//  EffectsInspector.swift
//  ClipStudio — Features/ProStudio/Inspector
//
//  Effect stack (ordered, enable/disable, keyframable intensity, reorder, remove)
//  and an effects browser whose tiles are live previews rendered on the clip's own
//  frame through the real effect pipeline.
//

import SwiftUI
import CoreImage

struct EffectsInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var loader = ClipFrameLoader()
    @State private var thumbnails: [EffectKind: UIImage] = [:]

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    var body: some View {
        if let clip = editor.clip {
            VStack(spacing: 12) {
                stackSection(clip)
                browserSection(clip)
            }
            .task(id: clip.id.uuidString + String(Int(vm.localTime(for: clip)))) {
                await loader.load(vm: vm, clip: clip, maxDimension: 360)
                await renderThumbnails(clip)
            }
        }
    }

    // MARK: Stack

    private func stackSection(_ clip: Clip) -> some View {
        InspectorSection(title: "التأثيرات المطبّقة", systemImage: "sparkles") {
            if clip.effects.isEmpty {
                Text("لا توجد تأثيرات. اختر من المكتبة بالأسفل.")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            ForEach(Array(clip.effects.enumerated()), id: \.element.id) { index, effect in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: effect.kind.symbol).foregroundStyle(Theme.Palette.accent)
                        Text(effect.kind.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button { move(effect.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(effect.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == clip.effects.count - 1)
                        Toggle("", isOn: Binding(get: { effect.isEnabled }, set: { value in
                            editor.update("تفعيل التأثير", key: "effect-enabled") { c in
                                if let i = c.effects.firstIndex(where: { $0.id == effect.id }) { c.effects[i].isEnabled = value }
                            }
                            vm.endContinuousEdit()
                        }))
                        .labelsHidden()
                        .tint(Theme.Palette.accent)
                        Button(role: .destructive) {
                            editor.update("حذف التأثير", key: "effect-remove") { c in c.effects.removeAll { $0.id == effect.id } }
                            vm.endContinuousEdit()
                        } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    PrecisionSlider(title: "الشدة", value: intensityBinding(effect.id), range: 0...1,
                                    defaultValue: effect.kind.defaultIntensity,
                                    format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                    keyframe: keyframeControl(effect, clip: clip),
                                    onEditingChanged: editor.editingChanged)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.surfaceHighlight.opacity(0.6)))
                .opacity(effect.isEnabled ? 1 : 0.55)
            }
        }
    }

    private func intensityBinding(_ effectID: UUID) -> Binding<Double> {
        Binding(get: {
            guard let clip = editor.clip, let effect = clip.effects.first(where: { $0.id == effectID }) else { return 0 }
            return effect.intensity.value(at: vm.localTime(for: clip))
        }, set: { value in
            editor.updateTimed("شدة التأثير", key: "effect-" + effectID.uuidString) { clip, local in
                if let index = clip.effects.firstIndex(where: { $0.id == effectID }) {
                    clip.effects[index].intensity.set(value, at: local)
                }
            }
        })
    }

    private func keyframeControl(_ effect: EffectInstance, clip: Clip) -> KeyframeControl? {
        guard !editor.appliesToSelection else { return nil }
        let local = vm.localTime(for: clip)
        let onKey = vm.isPlayheadInside(clip) && effect.intensity.keyframe(near: local, tolerance: vm.keyframeTolerance) != nil
        return KeyframeControl(isOnKeyframe: onKey, isAnimated: effect.intensity.isAnimated,
                               toggle: { vm.toggleEffectKeyframe(effect.id, clipID: clipID) })
    }

    private func move(_ effectID: UUID, by offset: Int) {
        editor.update("ترتيب التأثيرات", key: "effect-order") { clip in
            guard let index = clip.effects.firstIndex(where: { $0.id == effectID }) else { return }
            let target = min(max(index + offset, 0), clip.effects.count - 1)
            guard target != index else { return }
            let effect = clip.effects.remove(at: index)
            clip.effects.insert(effect, at: target)
        }
        vm.endContinuousEdit()
    }

    // MARK: Browser

    private func browserSection(_ clip: Clip) -> some View {
        InspectorSection(title: "مكتبة التأثيرات", systemImage: "square.grid.2x2") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 10) {
                ForEach(EffectKind.allCases) { kind in
                    Button {
                        editor.update("إضافة تأثير", key: "effect-add") { $0.effects.append(EffectInstance(kind: kind)) }
                        vm.endContinuousEdit()
                        Haptics.success()
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Theme.Palette.surfaceHighlight
                                if let image = thumbnails[kind] {
                                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Image(systemName: kind.symbol).font(.title3).foregroundStyle(Theme.Palette.accent)
                                }
                            }
                            .frame(height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(kind.title).font(.caption2).lineLimit(1)
                        }
                        .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("إضافة " + kind.title)
                }
            }
        }
    }

    private func renderThumbnails(_ clip: Clip) async {
        guard let base = loader.ciImage else { return }
        let small = FramePreviewRenderer.shared.downscaled(base, maxDimension: 200)
        let color = clip.color
        let lut = clip.lut
        var results: [EffectKind: UIImage] = [:]
        for kind in EffectKind.allCases {
            await Task.yield()
            if Task.isCancelled { return }
            var instance = EffectInstance(kind: kind)
            instance.intensity = KeyframedValue(max(kind.defaultIntensity, 0.6))
            let image = FramePreviewRenderer.shared.graded(small, color: color, lut: lut, effects: [instance])
            if let rendered = FramePreviewRenderer.shared.uiImage(image) { results[kind] = rendered }
        }
        thumbnails = results
    }
}

// MARK: - Transitions

struct TransitionInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var fromFrame: CIImage?
    @State private var toFrame: CIImage?
    @State private var previewKind: TransitionKind = .crossDissolve
    @State private var duration: Double = 0.5

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    private var previousClip: Clip? {
        guard let index = TimelineEngine.trackIndex(of: clipID, in: vm.timeline) else { return nil }
        let clips = vm.timeline.tracks[index].clips.sorted { $0.start < $1.start }
        guard let position = clips.firstIndex(where: { $0.id == clipID }), position > 0 else { return nil }
        return clips[position - 1]
    }

    var body: some View {
        if let clip = editor.clip {
            VStack(spacing: 12) {
                InspectorSection(title: "الانتقال إلى هذا المقطع", systemImage: "square.split.diagonal") {
                    if previousClip == nil {
                        Text("الانتقال يحتاج مقطعًا قبله في نفس المسار.")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    } else {
                        preview
                            .frame(height: 150)
                        HStack {
                            Text(clip.transitionIn.map { "الحالي: " + $0.kind.title } ?? "بدون انتقال")
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Spacer()
                        }
                        PrecisionSlider(title: "المدة", value: $duration, range: 0.1...3, defaultValue: vm.prefs.defaultTransitionDuration,
                                        step: 0.05, format: { Fmt.seconds($0, digits: 2) }) { editing in
                            if !editing, clip.transitionIn != nil {
                                vm.setTransition(clip.transitionIn?.kind ?? previewKind, duration: duration, for: clipID)
                                vm.endContinuousEdit()
                            }
                        }
                        HStack(spacing: 8) {
                            Button {
                                vm.setTransition(previewKind, duration: duration, for: clipID)
                                vm.endContinuousEdit()
                            } label: { Label("تطبيق", systemImage: "checkmark").frame(maxWidth: .infinity) }
                                .buttonStyle(.csPrimary)
                            if clip.transitionIn != nil {
                                Button(role: .destructive) {
                                    vm.setTransition(.none, for: clipID)
                                } label: { Label("إزالة", systemImage: "xmark").frame(maxWidth: .infinity) }
                                    .buttonStyle(.csSecondary)
                            }
                        }
                        Button {
                            vm.applyTransitionToTrack(previewKind, duration: duration, trackOf: clipID)
                        } label: {
                            Label("تطبيق على كل القطع في هذا المسار", systemImage: "square.stack").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.csSecondary)
                    }
                }
                InspectorSection(title: "الانتقالات", systemImage: "square.grid.3x3") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
                        ForEach(TransitionKind.allCases.filter { $0 != .none }) { kind in
                            Button {
                                previewKind = kind
                                Haptics.selection()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: kind.symbol).font(.title3)
                                    Text(kind.title).font(.caption2).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .foregroundStyle(previewKind == kind ? Color(hex: 0x1A1408) : Theme.Palette.textPrimary)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(previewKind == kind ? Theme.Palette.accent : Theme.Palette.surfaceHighlight))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("تضيف الانتقالات تداخلاً بين المقطعين بطول المدة، وتُزاح المقاطع التالية تلقائيًا.")
                        .font(.caption2)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .onAppear {
                previewKind = clip.transitionIn?.kind ?? .crossDissolve
                duration = clip.transitionIn?.duration.seconds ?? vm.prefs.defaultTransitionDuration
            }
            .task(id: clipID.uuidString + (previousClip?.id.uuidString ?? "")) { await loadFrames(clip) }
        }
    }

    private var preview: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
            let cycle = 2.4
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            let progress = min(max((phase - 0.2) / 0.6, 0), 1)
            TransitionFrameView(from: fromFrame, to: toFrame, kind: previewKind, progress: progress)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func loadFrames(_ clip: Clip) async {
        guard let previous = previousClip else { return }
        let previousImage = await vm.baseFrame(for: previous, maxDimension: 320)
        let currentImage = await vm.baseFrame(for: clip, maxDimension: 320)
        fromFrame = previousImage.map { FramePreviewRenderer.shared.graded($0, color: previous.color, lut: previous.lut) }
        toFrame = currentImage.map { FramePreviewRenderer.shared.graded($0, color: clip.color, lut: clip.lut) }
    }
}

/// Renders one transition frame with the real TransitionRenderer.
struct TransitionFrameView: View {
    let from: CIImage?
    let to: CIImage?
    let kind: TransitionKind
    let progress: Double

    var body: some View {
        ZStack {
            Color.black
            if let image = rendered {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(Theme.Palette.accent)
            }
        }
    }

    private var rendered: UIImage? {
        guard let from, let to else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 180)
        let a = fitted(from, canvas: canvas)
        let b = fitted(to, canvas: canvas)
        let frame = TransitionRenderer.blend(from: a, to: b, progress: progress, kind: kind, canvas: canvas)
        return FramePreviewRenderer.shared.uiImage(frame.cropped(to: canvas))
    }

    private func fitted(_ image: CIImage, canvas: CGRect) -> CIImage {
        let placed = LayerRenderer.fit(LayerRenderer.normalizedOrigin(image), mode: .fill, canvas: canvas.size).foreground
        return placed.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
    }
}
