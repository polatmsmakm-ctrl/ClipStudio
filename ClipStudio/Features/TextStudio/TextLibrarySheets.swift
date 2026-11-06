//
//  TextLibrarySheets.swift
//  ClipStudio — Features/TextStudio (Part 3)
//
//  • TitlesLibrarySheet — type your text once, then add it as any title design
//    (big title, lower thirds, banner, frame, underline, quote, typewriter, neon).
//  • GraphicsLibrarySheet — shapes, symbols, emoji and image overlays.
//  • WatermarkSheet — project-wide text or logo watermark.
//

import SwiftUI

// MARK: - Titles

struct TitlesLibrarySheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var subtitle = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 10) {
                        TextField("اكتب العنوان", text: $text, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($focused)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.surfaceHighlight))
                        TextField("السطر الثاني (للشريط السفلي واللافتة والاقتباس)", text: $subtitle)
                            .submitLabel(.done)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.surfaceHighlight))
                    }
                    Text("يُضاف عند رأس التشغيل، أو فوق المقاطع المحددة، أو بين نقطتي البداية والنهاية.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(TitleTemplate.all) { template in
                            Button {
                                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        || (template.design.usesSubtitle && !subtitle.isEmpty) else {
                                    focused = true
                                    vm.env.toasts.show("اكتب النص أولاً.", style: .info)
                                    return
                                }
                                vm.addTitle(template, text: text, subtitle: subtitle)
                                dismiss()
                            } label: {
                                TitleTemplateTile(template: template, text: text, subtitle: subtitle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("العناوين والنصوص")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
            }
            .screenBackground()
            .keyboardDoneToolbar()
            .onAppear { focused = true }
        }
    }
}

/// Live preview of a title design rendered with the real renderer.
struct TitleTemplateTile: View {
    let template: TitleTemplate
    let text: String
    let subtitle: String

    private var preview: UIImage? {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? template.title : text
        var content = template.content(text: sample, subtitle: subtitle.isEmpty && template.design.usesSubtitle ? "—" : subtitle)
        content.animationIn = .none
        content.animationOut = .none
        guard let image = GeneratedContentRenderer.shared.image(for: .text(content), canvas: CGSize(width: 640, height: 360),
                                                                 localTime: 2, clipDuration: 10) else { return nil }
        return FramePreviewRenderer.shared.uiImage(image)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x2A2D36), Color(hex: 0x15161B)], startPoint: .top, endPoint: .bottom)
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                }
            }
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 6) {
                Image(systemName: template.symbol).foregroundStyle(Theme.Palette.accent)
                Text(template.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("إضافة " + template.title)
    }
}

// MARK: - Graphics

struct GraphicsLibrarySheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var color = Color(hex: 0xE3B04B)
    @State private var showImages = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ColorPicker("لون الأشكال والرموز", selection: $color, supportsOpacity: true)
                    SectionTitle(title: "أشكال")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                        ForEach(ShapeKind.allCases, id: \.self) { kind in
                            tile(symbol: kind.symbol, title: kind.title) {
                                vm.addShape(kind, color: RGBAColor(color))
                                dismiss()
                            }
                        }
                    }
                    SectionTitle(title: "إيموجي")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                        ForEach(StickerCatalog.emojis, id: \.self) { emoji in
                            Button {
                                vm.addSticker(symbol: emoji, isEmoji: true, color: .white)
                                dismiss()
                            } label: {
                                Text(emoji).font(.system(size: 30))
                                    .frame(width: 52, height: 52)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.surfaceHighlight))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    SectionTitle(title: "رموز")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                        ForEach(StickerCatalog.symbols, id: \.self) { symbol in
                            Button {
                                vm.addSticker(symbol: symbol, isEmoji: false, color: RGBAColor(color))
                                dismiss()
                            } label: {
                                Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(color)
                                    .frame(width: 52, height: 52)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.surfaceHighlight))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                        }
                    }
                    SectionTitle(title: "صور")
                    Button {
                        showImages = true
                    } label: {
                        Label("إضافة صورة أو شعار فوق الفيديو", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .foregroundStyle(Color(hex: 0x1A1408))
                }
                .padding()
            }
            .navigationTitle("الأشكال والملصقات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
            }
            .screenBackground()
            .sheet(isPresented: $showImages) {
                MediaPickerSheet(title: "اختر صورة", kinds: [.image], allowsMultiple: false, confirmTitle: "إضافة") { assets in
                    if let asset = assets.first {
                        vm.addImageOverlay(asset)
                        dismiss()
                    }
                }
            }
        }
    }

    private func tile(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(color)
                Text(title).font(.caption2).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            .frame(width: 72, height: 72)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.surfaceHighlight))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("إضافة " + title)
    }
}

// MARK: - Watermark

struct WatermarkSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = WatermarkSettings()
    @State private var hasWatermark = false
    @State private var showLogoPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("علامة مائية على كل الفيديو", isOn: $hasWatermark)
                } footer: {
                    Text("تظهر في المعاينة وفي كل تصدير لهذا المشروع، ولا تُضاف داخل التسلسلات المتداخلة.")
                }
                if hasWatermark {
                    Section("المحتوى") {
                        Picker("النوع", selection: $draft.kind) {
                            ForEach(WatermarkKind.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if draft.kind == .text {
                            TextField("نص العلامة (مثل اسم الحساب)", text: $draft.text)
                                .submitLabel(.done)
                            ColorPicker("اللون", selection: Binding(get: { draft.textStyle.color.color },
                                                                    set: { draft.textStyle.color = RGBAColor($0) }))
                            PrecisionSlider(title: "الحجم", value: $draft.textStyle.sizeRatio, range: 0.015...0.1, defaultValue: 0.032,
                                            format: { Fmt.number($0 * 100, digits: 1) }, displayScale: 100)
                            Picker("السماكة", selection: $draft.textStyle.weight) {
                                ForEach(FontWeightOption.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        } else {
                            Button {
                                showLogoPicker = true
                            } label: {
                                HStack {
                                    Label(draft.imageAssetID == nil ? "اختيار الشعار" : "تغيير الشعار", systemImage: "photo")
                                    Spacer()
                                    if let id = draft.imageAssetID, let asset = vm.env.library.asset(id) {
                                        Text(asset.displayName).font(.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                                    }
                                }
                            }
                            PrecisionSlider(title: "العرض", value: $draft.size, range: 0.04...0.5, defaultValue: 0.16,
                                            format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100)
                        }
                    }
                    Section("المكان والشفافية") {
                        Picker("المكان", selection: $draft.position) {
                            ForEach(WatermarkPosition.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        PrecisionSlider(title: "الشفافية", value: $draft.opacity, range: 0.05...1, defaultValue: 0.8,
                                        format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100)
                        PrecisionSlider(title: "البعد عن الحافة", value: $draft.margin, range: 0...0.15, defaultValue: 0.035,
                                        format: { Fmt.number($0 * 100, digits: 1) + "%" }, displayScale: 100)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("العلامة المائية")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        vm.setWatermark(hasWatermark ? draft : nil)
                        if hasWatermark && !draft.isDrawable {
                            vm.env.toasts.show("العلامة بلا محتوى — أضف نصًا أو شعارًا.", style: .warning)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .screenBackground()
            .keyboardDoneToolbar()
            .onAppear {
                if let existing = vm.settings.watermark {
                    draft = existing
                    hasWatermark = true
                }
            }
            .sheet(isPresented: $showLogoPicker) {
                MediaPickerSheet(title: "اختر الشعار", kinds: [.image], allowsMultiple: false, confirmTitle: "اختيار") { assets in
                    if let asset = assets.first { draft.imageAssetID = asset.id }
                }
            }
        }
    }
}
