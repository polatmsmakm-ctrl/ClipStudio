//
//  TransformInspector.swift
//  ClipStudio — Features/ProStudio/Inspector
//
//  Position, scale, rotation, opacity (all keyframable), anchor point, flips,
//  fit mode, picture-in-picture presets, blend modes and keyframe navigation.
//  Solid-color layers also edit their color here.
//

import SwiftUI

struct TransformInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    var body: some View {
        if let clip = editor.clip {
            VStack(spacing: 12) {
                if case .solidColor(let color) = clip.source {
                    InspectorSection(title: "لون الطبقة", systemImage: "paintbrush") {
                        ColorPicker("اللون", selection: Binding(get: { color.color },
                                                                 set: { vm.setSolidColor(RGBAColor($0), for: clipID) }),
                                    supportsOpacity: false)
                    }
                }
                positionSection(clip)
                proportionSection(clip)
                motionSection
                if clip.mediaAssetID != nil || isImage(clip) {
                    fitSection(clip)
                    pipSection
                }
                compositingSection(clip)
                keyframeNavigation(clip)
            }
        }
    }

    private func isImage(_ clip: Clip) -> Bool {
        switch clip.source {
        case .image, .freezeFrame: true
        default: false
        }
    }

    // MARK: Aspect lock / stretch (Part 3)

    private func proportionSection(_ clip: Clip) -> some View {
        InspectorSection(title: "النسبة", systemImage: clip.transform.aspectLocked ? "lock" : "lock.open") {
            Toggle(isOn: Binding(get: { clip.transform.aspectLocked },
                                 set: { vm.setAspectLocked($0, for: clipID) })) {
                Label("قفل النسبة (مقابض الزوايا تحافظ على الشكل)", systemImage: "aspectratio")
            }
            .tint(Theme.Palette.accent)
            .font(.subheadline)
            if !clip.transform.aspectLocked || clip.transform.isStretched {
                PrecisionSlider(title: "العرض", value: stretchBinding(horizontal: true), range: ClipTransform.stretchRange,
                                defaultValue: 1, format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "الارتفاع", value: stretchBinding(horizontal: false), range: ClipTransform.stretchRange,
                                defaultValue: 1, format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
                if clip.transform.isStretched {
                    Button { vm.resetStretch(for: clipID) } label: {
                        Label("إرجاع النسبة الأصلية", systemImage: "arrow.counterclockwise")
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
    }

    private func stretchBinding(horizontal: Bool) -> Binding<Double> {
        editor.binding(horizontal ? "عرض الطبقة" : "ارتفاع الطبقة", key: horizontal ? "stretch-x" : "stretch-y",
                       read: { horizontal ? $0.transform.stretch.x : $0.transform.stretch.y },
                       write: { clip, value in
                           let range = ClipTransform.stretchRange
                           let v = min(max(value, range.lowerBound), range.upperBound)
                           if horizontal { clip.transform.stretch.x = v } else { clip.transform.stretch.y = v }
                       })
    }

    // MARK: Motion presets (Part 3)

    private var motionSection: some View {
        InspectorSection(title: "حركات جاهزة", systemImage: "wand.and.rays") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MotionPresetStore.shared.all.prefix(14)) { preset in
                        ChipButton(title: preset.name, systemImage: preset.symbol, isSelected: false) {
                            vm.applyMotionPreset(preset, to: editor.appliesToSelection ? vm.selection : [clipID])
                        }
                    }
                }
            }
            Button { vm.activeSheet = .motionPresets } label: {
                Label("كل الحركات وحفظ حركتك", systemImage: "square.grid.2x2")
            }
            .font(.caption.weight(.semibold))
        }
    }

    // MARK: Position / scale / rotation

    private func positionSection(_ clip: Clip) -> some View {
        InspectorSection(title: "الموضع والحجم", systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                         trailing: AnyView(resetButton)) {
            PrecisionSlider(title: "أفقي", value: positionBinding(\.x, key: "pos-x"), range: -100...100, defaultValue: 0,
                            format: { Fmt.number($0, digits: 1) + "%" },
                            keyframe: editor.keyframeControl(.position), onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "عمودي", value: positionBinding(\.y, key: "pos-y"), range: -100...100, defaultValue: 0,
                            format: { Fmt.number($0, digits: 1) + "%" },
                            keyframe: editor.keyframeControl(.position), onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "الحجم", value: editor.keyframed("الحجم", key: "scale", \Clip.transform.scale),
                            range: 0.05...5, defaultValue: 1,
                            format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                            keyframe: editor.keyframeControl(.scale), onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "الدوران", value: editor.keyframed("الدوران", key: "rotation", \Clip.transform.rotation),
                            range: -360...360, defaultValue: 0,
                            format: { Fmt.number($0, digits: 1) + "°" },
                            keyframe: editor.keyframeControl(.rotation), onEditingChanged: editor.editingChanged)
            HStack(spacing: 10) {
                Toggle(isOn: flipBinding(horizontal: true)) { Label("قلب أفقي", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .toggleStyle(.button)
                Toggle(isOn: flipBinding(horizontal: false)) { Label("قلب عمودي", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .toggleStyle(.button)
            }
            .font(.caption)
            DisclosureGroup("نقطة الارتكاز") {
                PrecisionSlider(title: "أفقي", value: anchorBinding(\.x, key: "anchor-x"), range: 0...1, defaultValue: 0.5,
                                format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "عمودي", value: anchorBinding(\.y, key: "anchor-y"), range: 0...1, defaultValue: 0.5,
                                format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
            }
            .font(.subheadline)
            .tint(Theme.Palette.accent)
        }
    }

    private var resetButton: some View {
        Button("إعادة ضبط") {
            editor.update("إعادة ضبط التحويل", key: "reset-transform") { clip in
                clip.transform = .identity
            }
            vm.endContinuousEdit()
        }
        .font(.caption)
    }

    /// Offset from the canvas center in percent of the canvas (0 = centered).
    private func positionBinding(_ axis: WritableKeyPath<Vec2, Double>, key: String) -> Binding<Double> {
        Binding(get: {
            guard let clip = editor.clip else { return 0 }
            return (clip.transform.position.value(at: vm.localTime(for: clip))[keyPath: axis] - 0.5) * 100
        }, set: { value in
            editor.updateTimed("الموضع", key: key) { clip, local in
                var position = clip.transform.position.value(at: local)
                position[keyPath: axis] = value / 100 + 0.5
                clip.transform.position.set(position, at: local)
            }
        })
    }

    private func anchorBinding(_ axis: WritableKeyPath<Vec2, Double>, key: String) -> Binding<Double> {
        editor.binding("نقطة الارتكاز", key: key, read: { $0.transform.anchor[keyPath: axis] },
                       write: { clip, value in clip.transform.anchor[keyPath: axis] = value })
    }

    private func flipBinding(horizontal: Bool) -> Binding<Bool> {
        Binding(get: {
            guard let clip = editor.clip else { return false }
            return horizontal ? clip.transform.flipHorizontal : clip.transform.flipVertical
        }, set: { value in
            editor.update(horizontal ? "قلب أفقي" : "قلب عمودي", key: horizontal ? "flip-h" : "flip-v") { clip in
                if horizontal { clip.transform.flipHorizontal = value } else { clip.transform.flipVertical = value }
            }
            vm.endContinuousEdit()
        })
    }

    // MARK: Fit & PiP

    private func fitSection(_ clip: Clip) -> some View {
        InspectorSection(title: "الملاءمة داخل اللوحة", systemImage: "rectangle.arrowtriangle.2.inward") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(FitMode.allCases, id: \.self) { mode in
                    ChipButton(title: mode.title, systemImage: mode.symbol, isSelected: clip.fitMode == mode) {
                        editor.update("وضع الملاءمة", key: "fit") { $0.fitMode = mode }
                        vm.endContinuousEdit()
                    }
                }
            }
        }
    }

    private var pipSection: some View {
        InspectorSection(title: "صورة داخل صورة", systemImage: "pip") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                pipButton("ملء الشاشة", "rectangle.fill", position: Vec2.center, scale: 1)
                pipButton("أعلى يمين", "rectangle.inset.topright.filled", position: Vec2(x: 0.775, y: 0.225), scale: 0.35)
                pipButton("أعلى يسار", "rectangle.inset.topleft.filled", position: Vec2(x: 0.225, y: 0.225), scale: 0.35)
                pipButton("أسفل يمين", "rectangle.inset.bottomright.filled", position: Vec2(x: 0.775, y: 0.775), scale: 0.35)
                pipButton("أسفل يسار", "rectangle.inset.bottomleft.filled", position: Vec2(x: 0.225, y: 0.775), scale: 0.35)
                pipButton("الوسط", "rectangle.center.inset.filled", position: Vec2.center, scale: 0.5)
            }
            Text("تلميح: ضع المقطع في مسار «طبقة علوية» فوق الفيديو الأساسي ليظهر كصورة داخل صورة.")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func pipButton(_ title: String, _ symbol: String, position: Vec2, scale: Double) -> some View {
        Button {
            editor.updateTimed("صورة داخل صورة", key: "pip") { clip, local in
                clip.transform.position.set(position, at: local)
                clip.transform.scale.set(scale, at: local)
            }
            vm.endContinuousEdit()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.surfaceHighlight))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    // MARK: Compositing

    private func compositingSection(_ clip: Clip) -> some View {
        InspectorSection(title: "المزج والشفافية", systemImage: "square.on.square") {
            PrecisionSlider(title: "الشفافية", value: editor.keyframed("الشفافية", key: "opacity", \Clip.transform.opacity),
                            range: 0...1, defaultValue: 1,
                            format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                            keyframe: editor.keyframeControl(.opacity), onEditingChanged: editor.editingChanged)
            if case .adjustment = clip.source {
                EmptyView()
            } else {
                InspectorRow(title: "نمط المزج", systemImage: "circle.lefthalf.striped.horizontal") {
                    Menu {
                        ForEach(BlendMode.allCases, id: \.self) { mode in
                            Button {
                                editor.update("نمط المزج", key: "blend") { $0.blendMode = mode }
                                vm.endContinuousEdit()
                            } label: {
                                if mode == clip.blendMode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(clip.blendMode.title)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    }
                }
            }
        }
    }

    // MARK: Keyframes

    private func keyframeNavigation(_ clip: Clip) -> some View {
        InspectorSection(title: "الإطارات المفتاحية", systemImage: "diamond") {
            HStack(spacing: 10) {
                Button { vm.jumpToKeyframe(next: false) } label: { Label("السابق", systemImage: "chevron.backward.2") }
                    .buttonStyle(.bordered)
                Button { vm.jumpToKeyframe(next: true) } label: { Label("التالي", systemImage: "chevron.forward.2") }
                    .buttonStyle(.bordered)
                Spacer()
                Text(Fmt.int(clip.allKeyframeTimes.count))
                    .font(Theme.Typo.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .font(.caption)
            Button {
                vm.activeSheet = .keyframes(clipID)
            } label: {
                Label("محرر الإطارات المفتاحية والانسيابية", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.csSecondary)
            Text("◆ بجانب أي قيمة يضيف إطارًا مفتاحيًا عند رأس التشغيل؛ بعدها أي تعديل للقيمة في موضع آخر ينشئ إطارًا جديدًا تلقائيًا.")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}
