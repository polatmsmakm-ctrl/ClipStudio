//
//  ColorWorkspaceView.swift
//  ClipStudio — Features/Color (color grading workspace)
//
//  Full grading workspace for a clip or an adjustment layer:
//  live GPU preview of the clip's real frame, before/after (split with a draggable
//  divider, side by side, or after only), RGB + luma histogram, and tabs for basic
//  sliders, tone curve, lift/gamma/gain wheels, LUTs (import .cube), looks
//  (built-in + saved) and shot matching. Edits are undoable and, with several clips
//  selected, apply to all of them. Also: the compact color tab used by the inspector.
//

import SwiftUI
import UniformTypeIdentifiers
import CoreImage

enum ColorWorkspaceTab: String, CaseIterable, Identifiable {
    case basic, curves, wheels, lut, looks, match

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: "أساسي"
        case .curves: "المنحنى"
        case .wheels: "العجلات"
        case .lut: "LUT"
        case .looks: "المظاهر"
        case .match: "مطابقة"
        }
    }

    var symbol: String {
        switch self {
        case .basic: "slider.horizontal.3"
        case .curves: "point.topleft.down.to.point.bottomright.curvepath"
        case .wheels: "circle.circle"
        case .lut: "cube"
        case .looks: "camera.filters"
        case .match: "eyedropper.halffull"
        }
    }
}

enum CompareMode: String, CaseIterable, Identifiable {
    case after, split, sideBySide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .after: "بعد"
        case .split: "قبل | بعد"
        case .sideBySide: "جنبًا لجنب"
        }
    }
}

struct ColorWorkspaceView: View {
    let vm: StudioViewModel
    let clipID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var loader = ClipFrameLoader()
    @State private var graded: UIImage?
    @State private var histogram = RGBHistogram.empty
    @State private var compare: CompareMode = .split
    @State private var splitFraction: Double = 0.5
    @State private var tab: ColorWorkspaceTab = .basic

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    var body: some View {
        NavigationStack {
            Group {
                if let clip = editor.clip {
                    if sizeClass == .regular {
                        HStack(spacing: 0) {
                            VStack(spacing: 10) {
                                previewArea
                                HistogramView(histogram: histogram).frame(height: 90)
                                comparePicker
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            controls(clip)
                                .frame(width: 400)
                                .background(Theme.Palette.surface)
                        }
                        .environment(\.layoutDirection, .leftToRight)
                    } else {
                        VStack(spacing: 8) {
                            previewArea
                                .frame(height: 230)
                            HStack(spacing: 8) {
                                HistogramView(histogram: histogram).frame(height: 54)
                                comparePicker.frame(width: 170)
                            }
                            controls(clip)
                        }
                        .padding(.horizontal, 10)
                    }
                } else {
                    EmptyStateView(systemImage: "paintpalette", title: "المقطع غير موجود", message: "ربما حُذف المقطع.")
                }
            }
            .screenBackground()
            .navigationTitle(editor.appliesToSelection ? "الألوان — " + Fmt.int(vm.selection.count) + " مقاطع" : "مساحة الألوان")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Button { vm.select(clipID); vm.copyAttributes() } label: { Label("نسخ التصحيح", systemImage: "doc.on.doc") }
                        Button { vm.pasteAttributes([.color, .lut]) } label: { Label("لصق التصحيح على المحدد", systemImage: "doc.on.clipboard") }
                            .disabled(!vm.clipboard.hasAttributes)
                        Divider()
                        Button(role: .destructive) {
                            editor.update("إعادة ضبط الألوان", key: "color-reset") { clip in
                                clip.color = .neutral
                                clip.lut = nil
                            }
                            vm.endContinuousEdit()
                        } label: { Label("إعادة ضبط كل التصحيح", systemImage: "arrow.counterclockwise") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .task(id: frameKey) {
                if let clip = editor.clip { await loader.load(vm: vm, clip: clip) }
            }
            .task(id: renderKey) { await render() }
            .keyboardDoneToolbar()
        }
    }

    private var frameKey: String {
        guard let clip = editor.clip else { return "none" }
        return clip.id.uuidString + "-" + String(Int(vm.localTime(for: clip) * 2))
    }

    private var renderKey: String {
        guard let clip = editor.clip else { return "none" }
        return String(clip.color.hashValue) + "-" + (clip.lut.map { $0.lutID.uuidString + String($0.intensity) } ?? "")
            + "-" + String(loader.ciImage != nil)
    }

    private func render() async {
        guard let base = loader.ciImage, let clip = editor.clip else { return }
        try? await Task.sleep(nanoseconds: 12_000_000)
        guard !Task.isCancelled else { return }
        let output = FramePreviewRenderer.shared.graded(base, color: clip.color, lut: clip.lut)
        graded = FramePreviewRenderer.shared.uiImage(output)
        histogram = FramePreviewRenderer.shared.histogram(output)
    }

    // MARK: Preview

    private var previewArea: some View {
        GeometryReader { geo in
            let size = loader.image?.size ?? CGSize(width: 16, height: 9)
            ZStack {
                Color.black
                switch compare {
                case .after:
                    frameImage(graded ?? loader.image)
                case .split:
                    let rect = AVMakeRectCompat.fit(size, in: CGRect(origin: .zero, size: geo.size))
                    ZStack(alignment: .topLeading) {
                        frameImage(graded ?? loader.image)
                        frameImage(loader.image)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: rect.minX + rect.width * CGFloat(splitFraction))
                            }
                        Rectangle()
                            .fill(Theme.Palette.textPrimary)
                            .frame(width: 2, height: rect.height)
                            .offset(x: rect.minX + rect.width * CGFloat(splitFraction) - 1, y: rect.minY)
                        Image(systemName: "arrow.left.and.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.Palette.textPrimary, Theme.Palette.accent)
                            .position(x: rect.minX + rect.width * CGFloat(splitFraction), y: rect.midY)
                        Text("قبل").font(.caption2.weight(.bold)).padding(4)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .offset(x: rect.minX + 6, y: rect.minY + 6)
                        Text("بعد").font(.caption2.weight(.bold)).padding(4)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .offset(x: rect.maxX - 40, y: rect.minY + 6)
                    }
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            splitFraction = Double(min(max((value.location.x - rect.minX) / max(rect.width, 1), 0), 1))
                        }
                    )
                case .sideBySide:
                    HStack(spacing: 4) {
                        frameImage(loader.image).overlay(alignment: .topLeading) { tag("قبل") }
                        frameImage(graded ?? loader.image).overlay(alignment: .topLeading) { tag("بعد") }
                    }
                }
                if loader.isLoading && loader.image == nil {
                    ProgressView().tint(Theme.Palette.accent)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func frameImage(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.bold)).padding(4)
            .background(Capsule().fill(.black.opacity(0.6)))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(6)
    }

    private var comparePicker: some View {
        Picker("المقارنة", selection: $compare) {
            ForEach(CompareMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Controls

    private func controls(_ clip: Clip) -> some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ColorWorkspaceTab.allCases) { option in
                        ChipButton(title: option.title, systemImage: option.symbol, isSelected: tab == option) { tab = option }
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.top, 8)
            .environment(\.layoutDirection, .rightToLeft)
            ScrollView {
                VStack(spacing: 12) {
                    switch tab {
                    case .basic: ColorBasicControls(editor: editor)
                    case .curves: curvesTab(clip)
                    case .wheels: wheelsTab(clip)
                    case .lut: LUTPickerPanel(vm: vm, clipID: clipID, base: loader.ciImage)
                    case .looks: ColorLooksPanel(vm: vm, clipID: clipID, base: loader.ciImage)
                    case .match: ColorMatchPanel(vm: vm, clipID: clipID, base: loader.ciImage)
                    }
                }
                .padding(12)
                .padding(.bottom, 30)
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }

    private func curvesTab(_ clip: Clip) -> some View {
        InspectorSection(title: "منحنى الدرجات", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                         trailing: AnyView(Button("إعادة ضبط") {
                             editor.update("إعادة ضبط المنحنى", key: "curve-reset") { $0.color.curve = .identity }
                             vm.endContinuousEdit()
                         }.font(.caption))) {
            CurveEditor(points: clip.color.curve.points, onChange: { points in
                editor.update("المنحنى", key: "curve") { $0.color.curve = ToneCurve(points: points) }
            }, onCommit: { vm.endContinuousEdit() })
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 360)
            Text("اسحب النقاط للأعلى للتفتيح وللأسفل للتغميق. ضغطتان على نقطة تعيدها لمكانها.")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func wheelsTab(_ clip: Clip) -> some View {
        InspectorSection(title: "عجلات الألوان", systemImage: "circle.circle",
                         trailing: AnyView(Button("إعادة ضبط") {
                             editor.update("إعادة ضبط العجلات", key: "wheels-reset") { $0.color.wheels = ColorWheels() }
                             vm.endContinuousEdit()
                         }.font(.caption))) {
            let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 16) {
                wheel("الظلال (Lift)", clip.color.wheels.lift, \.lift)
                wheel("الدرجات الوسطى (Gamma)", clip.color.wheels.gamma, \.gamma)
                wheel("الإضاءات (Gain)", clip.color.wheels.gain, \.gain)
            }
            Text("اسحب النقطة نحو اللون المطلوب. ضغطتان تعيدها للوسط.")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func wheel(_ title: String, _ value: RGBOffset, _ path: WritableKeyPath<ColorWheels, RGBOffset>) -> some View {
        ColorWheelView(title: title, offset: value, onChange: { offset in
            editor.update("عجلات الألوان", key: "wheel-" + title) { $0.color.wheels[keyPath: path] = offset }
        }, onCommit: { vm.endContinuousEdit() })
    }
}

// MARK: - Basic sliders

struct ColorBasicControls: View {
    let editor: ClipEditor

    var body: some View {
        VStack(spacing: 12) {
            InspectorSection(title: "الإضاءة", systemImage: "sun.max") {
                slider("التعريض", \.exposure)
                slider("السطوع", \.brightness)
                slider("التباين", \.contrast)
                slider("الإضاءات العالية", \.highlights)
                slider("الظلال", \.shadows)
                slider("الأبيض", \.whites)
                slider("الأسود", \.blacks)
            }
            InspectorSection(title: "اللون", systemImage: "drop") {
                slider("حرارة اللون", \.temperature)
                slider("الصبغة", \.tint)
                slider("التشبّع", \.saturation)
                slider("الحيوية", \.vibrance)
                slider("تدوير الألوان", \.hue)
            }
        }
    }

    private func slider(_ title: String, _ path: WritableKeyPath<ColorAdjustments, Double>) -> some View {
        PrecisionSlider(title: title,
                        value: editor.binding(title, key: "color-" + title, read: { $0.color[keyPath: path] },
                                              write: { clip, value in clip.color[keyPath: path] = value }),
                        range: -100...100, defaultValue: 0, step: 1,
                        format: { ($0 > 0 ? "+" : "") + Fmt.number($0, digits: 0) },
                        onEditingChanged: editor.editingChanged)
    }
}

// MARK: - Inspector color tab

struct ColorQuickInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    var body: some View {
        if let clip = editor.clip {
            VStack(spacing: 12) {
                Button {
                    vm.activeSheet = .colorWorkspace(clipID)
                } label: {
                    Label("مساحة الألوان الكاملة (منحنى، عجلات، LUT، مطابقة)", systemImage: "paintpalette")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.csPrimary)

                InspectorSection(title: "تصحيح سريع", systemImage: "slider.horizontal.3",
                                 trailing: AnyView(Button("إعادة ضبط") {
                                     editor.update("إعادة ضبط الألوان", key: "color-reset") { c in
                                         c.color = .neutral
                                         c.lut = nil
                                     }
                                     vm.endContinuousEdit()
                                 }.font(.caption))) {
                    quick("التعريض", \.exposure)
                    quick("التباين", \.contrast)
                    quick("التشبّع", \.saturation)
                    quick("حرارة اللون", \.temperature)
                    quick("الصبغة", \.tint)
                }

                InspectorSection(title: "LUT", systemImage: "cube") {
                    Menu {
                        Button("بدون") {
                            editor.update("LUT", key: "lut") { $0.lut = nil }
                            vm.endContinuousEdit()
                        }
                        ForEach(vm.env.lutLibrary.luts) { info in
                            Button(info.name) {
                                editor.update("LUT", key: "lut") { $0.lut = LUTReference(lutID: info.id, intensity: $0.lut?.intensity ?? 1) }
                                vm.endContinuousEdit()
                            }
                        }
                    } label: {
                        HStack {
                            Text(clip.lut.flatMap { vm.env.lutLibrary.info($0.lutID)?.name } ?? "بدون")
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    }
                    if clip.lut != nil {
                        PrecisionSlider(title: "الشدة", value: editor.binding("شدة LUT", key: "lut-intensity",
                                                                               read: { $0.lut?.intensity ?? 1 },
                                                                               write: { clip, value in clip.lut?.intensity = value }),
                                        range: 0...1, defaultValue: 1,
                                        format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                        onEditingChanged: editor.editingChanged)
                    }
                }

                InspectorSection(title: "مظاهر جاهزة", systemImage: "camera.filters") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(BuiltInLooks.all.prefix(8)) { look in
                            Button {
                                editor.update("مظهر: " + look.name, key: "look") { $0.color = look.adjustments }
                                vm.endContinuousEdit()
                            } label: {
                                Text(look.name)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.surfaceHighlight))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private func quick(_ title: String, _ path: WritableKeyPath<ColorAdjustments, Double>) -> some View {
        PrecisionSlider(title: title,
                        value: editor.binding(title, key: "color-" + title, read: { $0.color[keyPath: path] },
                                              write: { clip, value in clip.color[keyPath: path] = value }),
                        range: -100...100, defaultValue: 0, step: 1,
                        format: { ($0 > 0 ? "+" : "") + Fmt.number($0, digits: 0) },
                        onEditingChanged: editor.editingChanged)
    }
}
