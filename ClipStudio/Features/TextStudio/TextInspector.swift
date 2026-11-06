//
//  TextInspector.swift
//  ClipStudio — Features/TextStudio (Part 3)
//
//  The "Text" inspector tab: text and second line, title design and accent color,
//  font (any installed font, Arabic fonts first), weight, size, color, alignment,
//  letter and line spacing, width, outline, shadow / glow, background box,
//  entrance / exit / loop animations, caption highlighting, and saved text looks.
//  With several text layers selected, style changes apply to all of them.
//

import SwiftUI

struct TextInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var showFonts = false
    @State private var showSaveStyle = false
    @State private var styleName = ""
    @State private var draftText = ""
    @State private var draftSubtitle = ""
    @FocusState private var textFocused: Bool

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    private var content: TextContent? {
        guard let clip = editor.clip, case .text(let content) = clip.source else { return nil }
        return content
    }

    var body: some View {
        if let content {
            VStack(spacing: 12) {
                textSection(content)
                designSection(content)
                fontSection(content)
                decorationSection(content)
                animationSection(content)
                if content.caption != nil { captionSection(content) }
                presetsSection
            }
            .onAppear {
                draftText = content.caption?.composedText ?? content.text
                draftSubtitle = content.subtitle
            }
            .onChange(of: clipID) {
                if let current = self.content {
                    draftText = current.caption?.composedText ?? current.text
                    draftSubtitle = current.subtitle
                }
            }
            .sheet(isPresented: $showFonts) {
                FontPickerView(selected: content.style.fontName) { name in
                    set("الخط", key: "font") { $0.style.fontName = name }
                    vm.endContinuousEdit()
                }
            }
            .alert("حفظ نمط النص", isPresented: $showSaveStyle) {
                TextField("اسم النمط", text: $styleName)
                Button("حفظ") {
                    TextStylePresetStore.shared.save(content.style, name: styleName)
                    vm.env.toasts.show("تم حفظ النمط", style: .success)
                }
                Button("إلغاء", role: .cancel) {}
            }
        }
    }

    // MARK: Bindings

    private func set(_ name: String, key: String, _ change: @escaping (inout TextContent) -> Void) {
        editor.update(name, key: key) { clip in
            guard case .text(var content) = clip.source else { return }
            change(&content)
            clip.source = .text(content)
        }
    }

    private func value<T>(_ path: WritableKeyPath<TextContent, T>, _ fallback: T, name: String, key: String) -> Binding<T> {
        Binding(get: { content?[keyPath: path] ?? fallback },
                set: { newValue in set(name, key: key) { $0[keyPath: path] = newValue } })
    }

    private func color(_ path: WritableKeyPath<TextContent, RGBAColor>, name: String, key: String) -> Binding<Color> {
        Binding(get: { (content?[keyPath: path] ?? .white).color },
                set: { newValue in set(name, key: key) { $0[keyPath: path] = RGBAColor(newValue) } })
    }

    private func optionalColor(_ path: WritableKeyPath<TextContent, RGBAColor?>, fallback: RGBAColor, name: String, key: String) -> Binding<Color> {
        Binding(get: { (content?[keyPath: path] ?? fallback).color },
                set: { newValue in set(name, key: key) { $0[keyPath: path] = RGBAColor(newValue) } })
    }

    private func toggle(_ path: WritableKeyPath<TextContent, RGBAColor?>, enabled: RGBAColor, name: String) -> Binding<Bool> {
        Binding(get: { content?[keyPath: path] != nil },
                set: { on in
                    set(name, key: "toggle-" + name) { $0[keyPath: path] = on ? enabled : nil }
                    vm.endContinuousEdit()
                })
    }

    // MARK: Sections

    private func textSection(_ content: TextContent) -> some View {
        InspectorSection(title: content.caption != nil ? "نص الترجمة" : "النص", systemImage: "character.cursor.ibeam") {
            TextField("النص", text: $draftText, axis: .vertical)
                .lineLimit(1...6)
                .focused($textFocused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.surfaceHighlight))
                .onChange(of: draftText) { _, newValue in
                    guard textFocused else { return }
                    if content.caption != nil {
                        vm.updateCaptionText(clipID, text: newValue)
                    } else {
                        vm.updateText(clipID, name: "تعديل النص", coalesce: "text-" + clipID.uuidString) { $0.text = newValue }
                    }
                }
                .onChange(of: textFocused) { _, focused in
                    if !focused { vm.endContinuousEdit() }
                }
            if content.design.usesSubtitle {
                TextField(content.design == .quote ? "القائل" : "السطر الثاني", text: $draftSubtitle)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.surfaceHighlight))
                    .submitLabel(.done)
                    .onChange(of: draftSubtitle) { _, newValue in
                        vm.updateText(clipID, name: "السطر الثاني", coalesce: "subtitle-" + clipID.uuidString) { $0.subtitle = newValue }
                    }
            }
        }
    }

    private func designSection(_ content: TextContent) -> some View {
        InspectorSection(title: "التصميم", systemImage: "rectangle.3.group") {
            if content.caption == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TitleDesign.allCases, id: \.self) { design in
                            ChipButton(title: design.title, systemImage: design.symbol, isSelected: content.design == design) {
                                set("تصميم النص", key: "design") { $0.design = design }
                                vm.endContinuousEdit()
                            }
                        }
                    }
                }
            }
            if content.design != .plain {
                ColorPicker("لون التمييز", selection: color(\.accentColor, name: "لون التمييز", key: "accent"), supportsOpacity: false)
            }
        }
    }

    private func fontSection(_ content: TextContent) -> some View {
        InspectorSection(title: "الخط", systemImage: "textformat") {
            Button {
                showFonts = true
            } label: {
                HStack {
                    Text("الخط")
                    Spacer()
                    Text(FontCatalog.familyName(of: content.style.fontName))
                        .foregroundStyle(Theme.Palette.accent)
                    Image(systemName: "chevron.left").font(.caption).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .buttonStyle(.plain)
            if content.style.fontName == nil {
                Picker("السماكة", selection: value(\.style.weight, .bold, name: "سماكة الخط", key: "weight")) {
                    ForEach(FontWeightOption.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            PrecisionSlider(title: "الحجم", value: value(\.style.sizeRatio, 0.06, name: "حجم الخط", key: "size"),
                            range: 0.015...0.25, defaultValue: 0.06, format: { Fmt.number($0 * 100, digits: 1) }, displayScale: 100,
                            onEditingChanged: editor.editingChanged)
            ColorPicker("لون النص", selection: color(\.style.color, name: "لون النص", key: "text-color"))
            Picker("المحاذاة", selection: value(\.style.alignment, .center, name: "المحاذاة", key: "alignment")) {
                ForEach(TextAlignmentOption.allCases, id: \.self) { option in
                    Image(systemName: option.symbol).tag(option).accessibilityLabel(option.title)
                }
            }
            .pickerStyle(.segmented)
            PrecisionSlider(title: "تباعد الأحرف", value: value(\.style.kerning, 0, name: "تباعد الأحرف", key: "kerning"),
                            range: -0.1...0.5, defaultValue: 0, format: { Fmt.number($0 * 100, digits: 0) }, displayScale: 100,
                            onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "تباعد الأسطر", value: value(\.style.lineSpacing, 0, name: "تباعد الأسطر", key: "line-spacing"),
                            range: 0...1.5, defaultValue: 0, format: { Fmt.number($0 * 100, digits: 0) }, displayScale: 100,
                            onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "أقصى عرض", value: value(\.style.maxWidthRatio, 0.86, name: "عرض النص", key: "max-width"),
                            range: 0.2...1, defaultValue: 0.86, format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                            onEditingChanged: editor.editingChanged)
        }
    }

    private func decorationSection(_ content: TextContent) -> some View {
        InspectorSection(title: "الحدود والظل والخلفية", systemImage: "square.on.square") {
            Toggle("حدود", isOn: toggle(\.style.outlineColor, enabled: .black, name: "حدود النص"))
            if content.style.outlineColor != nil {
                ColorPicker("لون الحدود", selection: optionalColor(\.style.outlineColor, fallback: .black, name: "لون الحدود", key: "outline-color"))
                PrecisionSlider(title: "سماكة الحدود", value: value(\.style.outlineWidth, 0, name: "سماكة الحدود", key: "outline-width"),
                                range: 0...20, defaultValue: 6, format: { Fmt.number($0, digits: 1) },
                                onEditingChanged: editor.editingChanged)
            }
            Toggle("ظل / توهج", isOn: toggle(\.style.shadowColor, enabled: RGBAColor(r: 0, g: 0, b: 0, a: 0.55), name: "ظل النص"))
            if content.style.shadowColor != nil {
                ColorPicker("لون الظل", selection: optionalColor(\.style.shadowColor, fallback: .black, name: "لون الظل", key: "shadow-color"))
                PrecisionSlider(title: "النعومة", value: value(\.style.shadowRadius, 6, name: "نعومة الظل", key: "shadow-radius"),
                                range: 0...40, defaultValue: 6, format: { Fmt.number($0, digits: 0) },
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "الإزاحة", value: value(\.style.shadowOffsetY, 2, name: "إزاحة الظل", key: "shadow-offset"),
                                range: -20...20, defaultValue: 2, format: { Fmt.number($0, digits: 0) },
                                onEditingChanged: editor.editingChanged)
            }
            Toggle("خلفية", isOn: toggle(\.style.backgroundColor, enabled: RGBAColor(r: 0, g: 0, b: 0, a: 0.6), name: "خلفية النص"))
            if content.style.backgroundColor != nil {
                ColorPicker("لون الخلفية", selection: optionalColor(\.style.backgroundColor, fallback: .black, name: "لون الخلفية", key: "bg-color"))
                PrecisionSlider(title: "الهامش", value: value(\.style.backgroundPadding, 0.35, name: "هامش الخلفية", key: "bg-padding"),
                                range: 0...1.5, defaultValue: 0.35, format: { Fmt.number($0 * 100, digits: 0) }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "استدارة الزوايا", value: value(\.style.cornerRadius, 0.25, name: "استدارة الخلفية", key: "bg-radius"),
                                range: 0...1, defaultValue: 0.25, format: { Fmt.number($0 * 100, digits: 0) }, displayScale: 100,
                                onEditingChanged: editor.editingChanged)
            }
        }
    }

    private func animationSection(_ content: TextContent) -> some View {
        InspectorSection(title: "الحركة", systemImage: "sparkles") {
            Picker("الدخول", selection: value(\.animationIn, .fade, name: "حركة الدخول", key: "anim-in")) {
                ForEach(TextAnimation.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Picker("الخروج", selection: value(\.animationOut, .fade, name: "حركة الخروج", key: "anim-out")) {
                ForEach(TextAnimation.exitCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Picker("حركة مستمرة", selection: value(\.loop, .none, name: "حركة مستمرة", key: "loop")) {
                ForEach(LoopAnimation.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
        }
    }

    private func captionSection(_ content: TextContent) -> some View {
        InspectorSection(title: "تمييز الكلمات", systemImage: "highlighter") {
            Picker("طريقة التمييز", selection: Binding(
                get: { content.caption?.highlight ?? .none },
                set: { mode in set("تمييز الكلمات", key: "highlight") { $0.caption?.highlight = mode } })) {
                ForEach(CaptionHighlight.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            ColorPicker("لون الكلمة", selection: Binding(
                get: { (content.caption?.highlightColor ?? .white).color },
                set: { newValue in set("لون الكلمة", key: "highlight-color") { $0.caption?.highlightColor = RGBAColor(newValue) } }))
            if content.caption?.highlight == .box {
                ColorPicker("لون الصندوق", selection: Binding(
                    get: { (content.caption?.boxColor ?? .white).color },
                    set: { newValue in set("لون الصندوق", key: "box-color") { $0.caption?.boxColor = RGBAColor(newValue) } }))
            }
            Button {
                vm.activeSheet = .captions
            } label: {
                Label("محرر الترجمة", systemImage: "captions.bubble")
            }
        }
    }

    private var presetsSection: some View {
        InspectorSection(title: "أنماط جاهزة", systemImage: "paintpalette",
                         trailing: AnyView(Button {
                             styleName = ""
                             showSaveStyle = true
                         } label: {
                             Label("حفظ", systemImage: "plus")
                         }.font(.caption.weight(.semibold)))) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TextStylePresetStore.shared.all) { preset in
                        Button {
                            vm.applyTextStyle(preset.style, name: preset.name)
                        } label: {
                            VStack(spacing: 4) {
                                Text("أب Aa")
                                    .font(.system(size: 17, weight: preset.style.weight.swiftUIWeight))
                                    .foregroundStyle(preset.style.color.color)
                                    .frame(width: 64, height: 40)
                                    .background(RoundedRectangle(cornerRadius: 8)
                                        .fill(preset.style.backgroundColor?.color ?? Color.black.opacity(0.4)))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(preset.style.outlineColor?.color ?? .clear, lineWidth: 1))
                                Text(preset.name).font(.caption2).lineLimit(1)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .frame(width: 70)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !preset.isBuiltIn {
                                Button(role: .destructive) {
                                    TextStylePresetStore.shared.delete(preset.id)
                                } label: {
                                    Label("حذف النمط", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension FontWeightOption {
    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

// MARK: - Font picker

struct FontPickerView: View {
    let selected: String?
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var families: [FontFamilyInfo] = []
    @State private var query = ""
    @State private var expanded: String?

    private var filtered: [FontFamilyInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return families }
        return families.filter { $0.id.lowercased().contains(q) || $0.faces.contains { $0.displayName.lowercased().contains(q) } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "خط النظام", fontName: nil, sample: Font.system(size: 20, weight: .bold))
                }
                let arabic = filtered.filter(\.supportsArabic)
                if !arabic.isEmpty {
                    Section("خطوط تدعم العربية") {
                        ForEach(arabic) { family in familyRows(family) }
                    }
                }
                let others = filtered.filter { !$0.supportsArabic }
                if !others.isEmpty {
                    Section("خطوط أخرى (العربية تظهر بخط النظام)") {
                        ForEach(others) { family in familyRows(family) }
                    }
                }
            }
            .overlay {
                if families.isEmpty { ProgressView().tint(Theme.Palette.accent) }
            }
            .searchable(text: $query, prompt: "ابحث عن خط")
            .navigationTitle("الخط")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
            }
            .task { families = await FontCatalog.shared.families() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func familyRows(_ family: FontFamilyInfo) -> some View {
        if family.faces.count == 1, let face = family.faces.first {
            row(title: family.id, fontName: face.id, sample: Font.custom(face.id, size: 20))
        } else {
            DisclosureGroup(isExpanded: Binding(get: { expanded == family.id }, set: { expanded = $0 ? family.id : nil })) {
                ForEach(family.faces) { face in
                    row(title: face.displayName, fontName: face.id, sample: Font.custom(face.id, size: 18))
                }
            } label: {
                HStack {
                    Text(family.id).font(Font.custom(family.faces.first?.id ?? "", size: 18))
                    Spacer()
                    Text(Fmt.int(family.faces.count)).font(.caption).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
    }

    private func row(title: String, fontName: String?, sample: Font) -> some View {
        Button {
            onPick(fontName)
            Haptics.selection()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("أبجد هوز Abc 123").font(sample).foregroundStyle(Theme.Palette.textPrimary)
                    Text(title).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                if selected == fontName {
                    Image(systemName: "checkmark").foregroundStyle(Theme.Palette.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
