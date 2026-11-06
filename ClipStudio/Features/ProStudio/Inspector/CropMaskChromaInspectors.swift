//
//  CropMaskChromaInspectors.swift
//  ClipStudio — Features/ProStudio/Inspector
//
//  Visual editors on the clip's real frame:
//  • Crop — drag the box / corners, aspect presets, keyframable (animated reframing).
//  • Mask — rectangle / ellipse / linear, drag to place, corner to resize, feather, invert.
//  • Chroma key — eyedropper on the frame, tolerance / softness / spill, checkerboard preview.
//

import SwiftUI
import CoreImage

// MARK: - Crop

struct CropInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var loader = ClipFrameLoader()
    @State private var aspect: CropAspect = .free
    @State private var dragStart: RectValue?

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    enum CropAspect: String, CaseIterable, Identifiable {
        case free, canvas, wide, tall, square, portrait, classic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .free: "حر"
            case .canvas: "اللوحة"
            case .wide: "16:9"
            case .tall: "9:16"
            case .square: "1:1"
            case .portrait: "4:5"
            case .classic: "4:3"
            }
        }

        func ratio(canvas: CGSize) -> Double? {
            switch self {
            case .free: nil
            case .canvas: Double(canvas.width / max(canvas.height, 1))
            case .wide: 16.0 / 9
            case .tall: 9.0 / 16
            case .square: 1
            case .portrait: 4.0 / 5
            case .classic: 4.0 / 3
            }
        }
    }

    var body: some View {
        if let clip = editor.clip {
            let crop = clip.crop.value(at: vm.localTime(for: clip)).clamped()
            InspectorSection(title: "القص وإعادة التأطير", systemImage: "crop", trailing: AnyView(resetButton)) {
                FrameCanvas(image: loader.image, isLoading: loader.isLoading) { rect in
                    cropOverlay(rect: rect, crop: crop)
                }
                .frame(height: 230)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(CropAspect.allCases) { option in
                            ChipButton(title: option.title, isSelected: aspect == option) {
                                aspect = option
                                applyAspect(to: crop)
                            }
                        }
                    }
                }
                PrecisionSlider(title: "من اليسار", value: cropBinding(\.x), range: 0...0.98, defaultValue: 0,
                                format: { Fmt.number($0 * 100, digits: 1) + "%" }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "من الأعلى", value: cropBinding(\.y), range: 0...0.98, defaultValue: 0,
                                format: { Fmt.number($0 * 100, digits: 1) + "%" }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "العرض", value: cropBinding(\.width), range: 0.02...1, defaultValue: 1,
                                format: { Fmt.number($0 * 100, digits: 1) + "%" }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "الارتفاع", value: cropBinding(\.height), range: 0.02...1, defaultValue: 1,
                                format: { Fmt.number($0 * 100, digits: 1) + "%" }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
                if let control = editor.keyframeControl(.crop) {
                    Button(action: control.toggle) {
                        Label(control.isOnKeyframe ? "إزالة إطار القص المفتاحي" : "إطار مفتاحي للقص عند رأس التشغيل",
                              systemImage: control.isOnKeyframe ? "diamond.fill" : "diamond")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.csSecondary)
                }
                Text("القص يُطبّق على الصورة الأصلية قبل الملاءمة. بإطارات مفتاحية متعددة يتحرك التأطير (Ken Burns / إعادة تأطير).")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .task(id: frameKey(clip)) { await loader.load(vm: vm, clip: clip) }
        }
    }

    private func frameKey(_ clip: Clip) -> String {
        clip.id.uuidString + "-" + String(Int(vm.localTime(for: clip) * 2)) + "-" + String(clip.sourceRange?.start.value ?? 0)
    }

    private var resetButton: some View {
        Button("إعادة ضبط") {
            editor.update("إعادة ضبط القص", key: "crop-reset") { $0.crop = KeyframedValue(RectValue.full) }
            vm.endContinuousEdit()
        }
        .font(.caption)
    }

    private var imageAspect: Double {
        guard let size = loader.image?.size, size.height > 0 else { return 16.0 / 9 }
        return Double(size.width / size.height)
    }

    private func write(_ rect: RectValue) {
        let clamped = rect.clamped()
        editor.updateTimed("القص", key: "crop") { clip, local in clip.crop.set(clamped, at: local) }
    }

    private func cropBinding(_ path: WritableKeyPath<RectValue, Double>) -> Binding<Double> {
        Binding(get: {
            guard let clip = editor.clip else { return 0 }
            return clip.crop.value(at: vm.localTime(for: clip)).clamped()[keyPath: path]
        }, set: { value in
            guard let clip = editor.clip else { return }
            var rect = clip.crop.value(at: vm.localTime(for: clip)).clamped()
            rect[keyPath: path] = value
            write(rect)
        })
    }

    private func applyAspect(to crop: RectValue) {
        guard let ratio = aspect.ratio(canvas: vm.canvasSize) else { return }
        var rect = crop
        let normalizedRatio = ratio / imageAspect
        if rect.width / max(rect.height, 0.0001) > normalizedRatio {
            rect.width = rect.height * normalizedRatio
        } else {
            rect.height = rect.width / normalizedRatio
        }
        if rect.width > 1 { rect.height /= rect.width; rect.width = 1 }
        if rect.height > 1 { rect.width /= rect.height; rect.height = 1 }
        rect.x = crop.x + (crop.width - rect.width) / 2
        rect.y = crop.y + (crop.height - rect.height) / 2
        write(rect)
        vm.endContinuousEdit()
    }

    @ViewBuilder
    private func cropOverlay(rect: CGRect, crop: RectValue) -> some View {
        let box = CGRect(x: rect.minX + CGFloat(crop.x) * rect.width, y: rect.minY + CGFloat(crop.y) * rect.height,
                         width: CGFloat(crop.width) * rect.width, height: CGFloat(crop.height) * rect.height)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(rect)
                path.addRect(box)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                path.addRect(box)
                for i in 1...2 {
                    let x = box.minX + box.width * CGFloat(i) / 3
                    let y = box.minY + box.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: box.minY))
                    path.addLine(to: CGPoint(x: x, y: box.maxY))
                    path.move(to: CGPoint(x: box.minX, y: y))
                    path.addLine(to: CGPoint(x: box.maxX, y: y))
                }
            }
            .stroke(Theme.Palette.accent, lineWidth: 1.2)
            .allowsHitTesting(false)

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStart == nil { dragStart = crop }
                            guard let start = dragStart else { return }
                            var moved = start
                            moved.x = start.x + Double(value.translation.width / max(rect.width, 1))
                            moved.y = start.y + Double(value.translation.height / max(rect.height, 1))
                            write(moved)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            vm.endContinuousEdit()
                        }
                )

            ForEach(0..<4, id: \.self) { corner in
                let point = CGPoint(x: corner % 2 == 0 ? box.minX : box.maxX, y: corner < 2 ? box.minY : box.maxY)
                Circle()
                    .fill(Theme.Palette.textPrimary)
                    .overlay(Circle().strokeBorder(Theme.Palette.accent, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle().inset(by: -10))
                    .position(point)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragStart == nil { dragStart = crop }
                                guard let start = dragStart else { return }
                                write(resized(start, corner: corner, dx: Double(value.translation.width / max(rect.width, 1)),
                                              dy: Double(value.translation.height / max(rect.height, 1))))
                            }
                            .onEnded { _ in
                                dragStart = nil
                                vm.endContinuousEdit()
                            }
                    )
            }
        }
    }

    private func resized(_ start: RectValue, corner: Int, dx: Double, dy: Double) -> RectValue {
        var minX = start.x, minY = start.y, maxX = start.x + start.width, maxY = start.y + start.height
        if corner % 2 == 0 { minX = min(max(0, minX + dx), maxX - 0.02) } else { maxX = max(min(1, maxX + dx), minX + 0.02) }
        if corner < 2 { minY = min(max(0, minY + dy), maxY - 0.02) } else { maxY = max(min(1, maxY + dy), minY + 0.02) }
        var rect = RectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let ratio = aspect.ratio(canvas: vm.canvasSize) {
            let normalizedRatio = ratio / imageAspect
            rect.height = rect.width / normalizedRatio
            if corner < 2 { rect.y = maxY - rect.height }
        }
        return rect
    }
}

// MARK: - Mask

struct MaskInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var loader = ClipFrameLoader()
    @State private var dragStart: MaskSettings?

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    var body: some View {
        if let clip = editor.clip {
            InspectorSection(title: "القناع", systemImage: "circle.dashed") {
                Toggle("تفعيل القناع", isOn: Binding(get: { clip.mask?.isEnabled ?? false }, set: { enabled in
                    editor.update("القناع", key: "mask-toggle") { c in
                        if c.mask == nil { c.mask = MaskSettings() }
                        c.mask?.isEnabled = enabled
                    }
                    vm.endContinuousEdit()
                }))
                .tint(Theme.Palette.accent)

                if let mask = clip.mask, mask.isEnabled {
                    FrameCanvas(image: loader.image, isLoading: loader.isLoading) { rect in
                        maskOverlay(rect: rect, mask: mask)
                    }
                    .frame(height: 220)

                    Picker("الشكل", selection: maskBinding(\.shape)) {
                        ForEach(MaskShape.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    PrecisionSlider(title: "التنعيم", value: maskDouble(\.feather), range: 0...1, defaultValue: 0.15,
                                    format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                    onEditingChanged: editor.editingChanged)
                    PrecisionSlider(title: "الدوران", value: maskDouble(\.rotation), range: -180...180, defaultValue: 0,
                                    format: { Fmt.number($0, digits: 0) + "°" }, onEditingChanged: editor.editingChanged)
                    if mask.shape != .linear {
                        PrecisionSlider(title: "العرض", value: maskVec(\.size, \.x), range: 0.02...1.5, defaultValue: 0.6,
                                        format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                        onEditingChanged: editor.editingChanged)
                        PrecisionSlider(title: "الارتفاع", value: maskVec(\.size, \.y), range: 0.02...1.5, defaultValue: 0.6,
                                        format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                        onEditingChanged: editor.editingChanged)
                    }
                    Toggle("عكس القناع", isOn: Binding(get: { mask.invert }, set: { value in
                        editor.update("عكس القناع", key: "mask-invert") { $0.mask?.invert = value }
                        vm.endContinuousEdit()
                    }))
                    .tint(Theme.Palette.accent)
                    Button(role: .destructive) {
                        editor.update("حذف القناع", key: "mask-remove") { $0.mask = nil }
                        vm.endContinuousEdit()
                    } label: {
                        Label("حذف القناع", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.csSecondary)
                }
            }
            .task(id: clip.id.uuidString + String(Int(vm.localTime(for: clip) * 2))) { await loader.load(vm: vm, clip: clip) }
        }
    }

    private func maskBinding<T>(_ path: WritableKeyPath<MaskSettings, T>) -> Binding<T> {
        Binding(get: {
            (editor.clip?.mask ?? MaskSettings())[keyPath: path]
        }, set: { value in
            editor.update("القناع", key: "mask") { clip in
                var mask = clip.mask ?? MaskSettings()
                mask[keyPath: path] = value
                clip.mask = mask
            }
            vm.endContinuousEdit()
        })
    }

    private func maskDouble(_ path: WritableKeyPath<MaskSettings, Double>) -> Binding<Double> {
        Binding(get: { (editor.clip?.mask ?? MaskSettings())[keyPath: path] }, set: { value in
            editor.update("القناع", key: "mask-value") { clip in
                var mask = clip.mask ?? MaskSettings()
                mask[keyPath: path] = value
                clip.mask = mask
            }
        })
    }

    private func maskVec(_ path: WritableKeyPath<MaskSettings, Vec2>, _ axis: WritableKeyPath<Vec2, Double>) -> Binding<Double> {
        Binding(get: { (editor.clip?.mask ?? MaskSettings())[keyPath: path][keyPath: axis] }, set: { value in
            editor.update("القناع", key: "mask-size") { clip in
                var mask = clip.mask ?? MaskSettings()
                mask[keyPath: path][keyPath: axis] = value
                clip.mask = mask
            }
        })
    }

    @ViewBuilder
    private func maskOverlay(rect: CGRect, mask: MaskSettings) -> some View {
        let center = CGPoint(x: rect.minX + CGFloat(mask.center.x) * rect.width, y: rect.minY + CGFloat(mask.center.y) * rect.height)
        let size = CGSize(width: CGFloat(mask.size.x) * rect.width, height: CGFloat(mask.size.y) * rect.height)
        let shapeView: AnyView = {
            switch mask.shape {
            case .ellipse:
                return AnyView(Ellipse().stroke(Theme.Palette.accent, lineWidth: 2).frame(width: size.width, height: size.height))
            case .rectangle:
                return AnyView(Rectangle().stroke(Theme.Palette.accent, lineWidth: 2).frame(width: size.width, height: size.height))
            case .linear:
                return AnyView(Rectangle().fill(Theme.Palette.accent).frame(width: rect.width * 1.6, height: 2))
            }
        }()
        ZStack(alignment: .topLeading) {
            shapeView
                .rotationEffect(.degrees(mask.rotation))
                .position(center)
                .allowsHitTesting(false)
            Circle()
                .fill(Theme.Palette.accent)
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: "move.3d").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: 0x1A1408)))
                .contentShape(Circle().inset(by: -12))
                .position(center)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStart == nil { dragStart = mask }
                            guard let start = dragStart else { return }
                            let moved = Vec2(x: min(max(start.center.x + Double(value.translation.width / max(rect.width, 1)), -0.5), 1.5),
                                             y: min(max(start.center.y + Double(value.translation.height / max(rect.height, 1)), -0.5), 1.5))
                            editor.update("موضع القناع", key: "mask-move") { $0.mask?.center = moved }
                        }
                        .onEnded { _ in
                            dragStart = nil
                            vm.endContinuousEdit()
                        }
                )
            if mask.shape != .linear {
                Circle()
                    .fill(Theme.Palette.textPrimary)
                    .overlay(Circle().strokeBorder(Theme.Palette.accent, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle().inset(by: -10))
                    .position(x: center.x + size.width / 2, y: center.y + size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragStart == nil { dragStart = mask }
                                guard let start = dragStart else { return }
                                let newSize = Vec2(x: min(max(start.size.x + 2 * Double(value.translation.width / max(rect.width, 1)), 0.02), 1.5),
                                                   y: min(max(start.size.y + 2 * Double(value.translation.height / max(rect.height, 1)), 0.02), 1.5))
                                editor.update("حجم القناع", key: "mask-size") { $0.mask?.size = newSize }
                            }
                            .onEnded { _ in
                                dragStart = nil
                                vm.endContinuousEdit()
                            }
                    )
            }
        }
    }
}

// MARK: - Chroma key

struct ChromaKeyInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var loader = ClipFrameLoader()
    @State private var keyedPreview: UIImage?
    @State private var eyedropper = false

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    var body: some View {
        if let clip = editor.clip {
            InspectorSection(title: "مفتاح الكروما (الشاشة الخضراء)", systemImage: "person.crop.rectangle") {
                Toggle("تفعيل", isOn: Binding(get: { clip.chromaKey?.isEnabled ?? false }, set: { enabled in
                    editor.update("مفتاح الكروما", key: "chroma-toggle") { c in
                        if c.chromaKey == nil { c.chromaKey = ChromaKeySettings() }
                        c.chromaKey?.isEnabled = enabled
                    }
                    vm.endContinuousEdit()
                }))
                .tint(Theme.Palette.accent)

                if let key = clip.chromaKey, key.isEnabled {
                    FrameCanvas(image: eyedropper ? loader.image : (keyedPreview ?? loader.image), isLoading: loader.isLoading) { rect in
                        Color.white.opacity(0.001)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .gesture(
                                SpatialTapGesture().onEnded { value in
                                    guard eyedropper else { return }
                                    pick(at: value.location, in: rect)
                                }
                            )
                    }
                    .frame(height: 220)
                    .overlay(alignment: .topTrailing) {
                        if eyedropper {
                            StatusPill(text: "اضغط على اللون المراد إزالته", systemImage: "eyedropper")
                                .padding(8)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            eyedropper.toggle()
                        } label: {
                            Label(eyedropper ? "إنهاء القطارة" : "قطارة اللون", systemImage: "eyedropper.halffull")
                        }
                        .buttonStyle(.bordered)
                        ColorPicker("", selection: Binding(get: { key.keyColor.color }, set: { color in
                            editor.update("لون المفتاح", key: "chroma-color") { $0.chromaKey?.keyColor = RGBAColor(color) }
                            vm.endContinuousEdit()
                        }), supportsOpacity: false)
                        .labelsHidden()
                        Spacer()
                        Button("أخضر") { setKeyColor(.chromaGreen) }.buttonStyle(.bordered)
                        Button("أزرق") { setKeyColor(RGBAColor(r: 0.0, g: 0.28, b: 0.9)) }.buttonStyle(.bordered)
                    }
                    .font(.caption)

                    PrecisionSlider(title: "التسامح", value: chromaBinding(\.tolerance), range: 0...1, defaultValue: 0.3,
                                    format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                    onEditingChanged: editor.editingChanged)
                    PrecisionSlider(title: "نعومة الحواف", value: chromaBinding(\.softness), range: 0...1, defaultValue: 0.12,
                                    format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                    onEditingChanged: editor.editingChanged)
                    PrecisionSlider(title: "إزالة الانسكاب اللوني", value: chromaBinding(\.spillSuppression), range: 0...1,
                                    defaultValue: 0.5, format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                    onEditingChanged: editor.editingChanged)
                    Text("ضع هذا المقطع في مسار «طبقة علوية» فوق الخلفية الجديدة.")
                        .font(.caption2)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .task(id: clip.id.uuidString + String(Int(vm.localTime(for: clip) * 2))) { await loader.load(vm: vm, clip: clip) }
            .task(id: previewKey(clip)) { await renderPreview(clip) }
        }
    }

    private func previewKey(_ clip: Clip) -> String {
        guard let key = clip.chromaKey else { return "none" }
        return String(key.hashValue) + "-" + String(loader.ciImage != nil)
    }

    private func setKeyColor(_ color: RGBAColor) {
        editor.update("لون المفتاح", key: "chroma-color") { $0.chromaKey?.keyColor = color }
        vm.endContinuousEdit()
    }

    private func chromaBinding(_ path: WritableKeyPath<ChromaKeySettings, Double>) -> Binding<Double> {
        Binding(get: { (editor.clip?.chromaKey ?? ChromaKeySettings())[keyPath: path] }, set: { value in
            editor.update("مفتاح الكروما", key: "chroma-value") { clip in
                var key = clip.chromaKey ?? ChromaKeySettings()
                key[keyPath: path] = value
                clip.chromaKey = key
            }
        })
    }

    private func renderPreview(_ clip: Clip) async {
        guard let base = loader.ciImage, let key = clip.chromaKey, key.isEnabled else {
            keyedPreview = nil
            return
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !Task.isCancelled else { return }
        let extent = base.extent
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 0.32, green: 0.32, blue: 0.34),
            "inputColor1": CIColor(red: 0.2, green: 0.2, blue: 0.22),
            "inputWidth": max(8, extent.width / 40),
            "inputSharpness": 1
        ])?.outputImage?.cropped(to: extent) ?? CIImage(color: .gray).cropped(to: extent)
        let keyed = ChromaKeyRenderer.apply(key, to: base).composited(over: checker)
        keyedPreview = FramePreviewRenderer.shared.uiImage(keyed)
    }

    private func pick(at location: CGPoint, in rect: CGRect) {
        guard let image = loader.ciImage else { return }
        let extent = image.extent
        let nx = (location.x - rect.minX) / max(rect.width, 1)
        let ny = (location.y - rect.minY) / max(rect.height, 1)
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return }
        let point = CGPoint(x: extent.minX + nx * extent.width, y: extent.maxY - ny * extent.height)
        let sample = CGRect(x: point.x - 2, y: point.y - 2, width: 5, height: 5).intersection(extent)
        guard sample.width > 0, sample.height > 0 else { return }
        var pixels = [UInt8](repeating: 0, count: 5 * 5 * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            FramePreviewRenderer.shared.context.render(image, toBitmap: base, rowBytes: 5 * 4, bounds: sample,
                                                       format: .RGBA8, colorSpace: ColorPipeline.sRGB)
        }
        let count = Int(sample.width) * Int(sample.height)
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<max(count, 1) {
            r += Double(pixels[i * 4]) / 255
            g += Double(pixels[i * 4 + 1]) / 255
            b += Double(pixels[i * 4 + 2]) / 255
        }
        let n = Double(max(count, 1))
        setKeyColor(RGBAColor(r: r / n, g: g / n, b: b / n))
        eyedropper = false
        Haptics.success()
    }
}
