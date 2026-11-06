//
//  GraphicsInspector.swift
//  ClipStudio — Features/TextStudio (Part 3)
//
//  The "Shape" inspector tab for shapes (kind, width/height, fill, stroke, corner
//  radius) and stickers (emoji or symbol, color, size, loop animation).
//

import SwiftUI

struct GraphicsInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var emojiDraft = ""
    @State private var showSymbols = false

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    var body: some View {
        if let clip = editor.clip {
            VStack(spacing: 12) {
                switch clip.source {
                case .shape(let shape): shapeSections(shape)
                case .sticker(let sticker): stickerSections(sticker)
                default: EmptyView()
                }
            }
            .sheet(isPresented: $showSymbols) {
                SymbolPickerSheet { symbol in
                    updateSticker("رمز الملصق") {
                        $0.symbolName = symbol
                        $0.isEmoji = false
                    }
                    vm.endContinuousEdit()
                }
            }
        }
    }

    // MARK: Shape

    private func updateShape(_ name: String, key: String = "", _ change: @escaping (inout ShapeContent) -> Void) {
        editor.update(name, key: "shape-" + (key.isEmpty ? name : key)) { clip in
            guard case .shape(var shape) = clip.source else { return }
            change(&shape)
            clip.source = .shape(shape)
        }
    }

    private func shapeValue(_ path: WritableKeyPath<ShapeContent, Double>, _ fallback: Double, name: String) -> Binding<Double> {
        Binding(get: {
            guard let clip = editor.clip, case .shape(let shape) = clip.source else { return fallback }
            return shape[keyPath: path]
        }, set: { value in updateShape(name) { $0[keyPath: path] = value } })
    }

    @ViewBuilder
    private func shapeSections(_ shape: ShapeContent) -> some View {
        InspectorSection(title: "الشكل", systemImage: "square.on.circle") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ShapeKind.allCases, id: \.self) { kind in
                        ChipButton(title: kind.title, systemImage: kind.symbol, isSelected: shape.kind == kind) {
                            updateShape("نوع الشكل") { $0.kind = kind }
                            vm.endContinuousEdit()
                        }
                    }
                }
            }
            PrecisionSlider(title: "العرض", value: shapeValue(\.size.x, 0.4, name: "عرض الشكل"), range: 0.01...1.2, defaultValue: 0.4,
                            format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100, onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "الارتفاع", value: shapeValue(\.size.y, 0.2, name: "ارتفاع الشكل"), range: 0.005...1.2, defaultValue: 0.2,
                            format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100, onEditingChanged: editor.editingChanged)
            if shape.kind == .roundedRectangle || shape.kind == .bubble {
                PrecisionSlider(title: "استدارة الزوايا", value: shapeValue(\.cornerRadius, 0.2, name: "استدارة الزوايا"),
                                range: 0...0.5, defaultValue: 0.2, format: { Fmt.number($0 * 200, digits: 0) + "%" },
                                displayScale: 200, onEditingChanged: editor.editingChanged)
            }
        }
        InspectorSection(title: "التعبئة والحدود", systemImage: "paintbrush") {
            Toggle(shape.kind == .line ? "اللون" : "تعبئة", isOn: Binding(
                get: { shape.fill != nil },
                set: { on in
                    updateShape("تعبئة الشكل") { $0.fill = on ? RGBAColor(hex: 0xE3B04B) : nil }
                    vm.endContinuousEdit()
                }))
            if let fill = shape.fill {
                ColorPicker("لون التعبئة", selection: Binding(get: { fill.color },
                                                             set: { c in updateShape("لون التعبئة") { $0.fill = RGBAColor(c) } }))
            }
            Toggle("حدود", isOn: Binding(
                get: { shape.stroke != nil },
                set: { on in
                    updateShape("حدود الشكل") { $0.stroke = on ? .white : nil }
                    vm.endContinuousEdit()
                }))
            if let stroke = shape.stroke {
                ColorPicker("لون الحدود", selection: Binding(get: { stroke.color },
                                                            set: { c in updateShape("لون الحدود") { $0.stroke = RGBAColor(c) } }))
            }
            if shape.stroke != nil || shape.kind == .line {
                PrecisionSlider(title: "سماكة الخط", value: shapeValue(\.strokeWidth, 0.006, name: "سماكة الحدود"),
                                range: 0.001...0.05, defaultValue: 0.006, format: { Fmt.number($0 * 1000, digits: 0) },
                                displayScale: 1000, onEditingChanged: editor.editingChanged)
            }
        }
    }

    // MARK: Sticker

    private func updateSticker(_ name: String, key: String = "", _ change: @escaping (inout StickerContent) -> Void) {
        editor.update(name, key: "sticker-" + (key.isEmpty ? name : key)) { clip in
            guard case .sticker(var sticker) = clip.source else { return }
            change(&sticker)
            clip.source = .sticker(sticker)
        }
    }

    @ViewBuilder
    private func stickerSections(_ sticker: StickerContent) -> some View {
        InspectorSection(title: "الملصق", systemImage: "face.smiling") {
            HStack(spacing: 14) {
                Group {
                    if sticker.isEmoji {
                        Text(sticker.symbolName).font(.system(size: 40))
                    } else {
                        Image(systemName: sticker.symbolName).font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(sticker.color.color)
                    }
                }
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.surfaceHighlight))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("إيموجي", text: $emojiDraft)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit(applyEmoji)
                        Button("تطبيق", action: applyEmoji).disabled(emojiDraft.isEmpty)
                    }
                    Button {
                        showSymbols = true
                    } label: {
                        Label("اختيار رمز", systemImage: "square.grid.3x3")
                    }
                }
            }
            if !sticker.isEmoji {
                ColorPicker("اللون", selection: Binding(get: { sticker.color.color },
                                                        set: { c in updateSticker("لون الملصق") { $0.color = RGBAColor(c) } }))
            }
            PrecisionSlider(title: "الحجم", value: Binding(get: { sticker.sizeRatio },
                                                           set: { v in updateSticker("حجم الملصق") { $0.sizeRatio = v } }),
                            range: 0.03...0.8, defaultValue: 0.18, format: { Fmt.number($0 * 100, digits: 0) + "%" },
                            displayScale: 100, onEditingChanged: editor.editingChanged)
            Picker("حركة مستمرة", selection: Binding(get: { sticker.loop },
                                                     set: { loop in updateSticker("حركة الملصق") { $0.loop = loop } })) {
                ForEach(LoopAnimation.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
        }
    }

    private func applyEmoji() {
        let trimmed = emojiDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return }
        updateSticker("إيموجي") {
            $0.symbolName = String(first)
            $0.isEmoji = true
        }
        vm.endContinuousEdit()
        emojiDraft = ""
    }
}

// MARK: - Symbol picker

struct SymbolPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var symbols: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? StickerCatalog.symbols : StickerCatalog.symbols.filter { $0.contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 10)], spacing: 10) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            onPick(symbol)
                            dismiss()
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 24, weight: .medium))
                                .frame(width: 58, height: 58)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.surfaceHighlight))
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
                .padding()
            }
            .searchable(text: $query, prompt: "ابحث بالإنجليزية (heart, star…)")
            .navigationTitle("الرموز")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
            }
            .screenBackground()
        }
        .presentationDetents([.medium, .large])
    }
}

enum StickerCatalog {
    static let symbols: [String] = [
        "star.fill", "heart.fill", "hand.thumbsup.fill", "hand.thumbsdown.fill", "flame.fill", "bolt.fill", "sparkles",
        "crown.fill", "checkmark.seal.fill", "xmark.octagon.fill", "exclamationmark.triangle.fill", "questionmark.circle.fill",
        "bell.fill", "bell.badge.fill", "play.circle.fill", "pause.circle.fill", "music.note", "mic.fill", "camera.fill",
        "video.fill", "photo.fill", "location.fill", "mappin.and.ellipse", "globe", "airplane", "car.fill", "house.fill",
        "cart.fill", "bag.fill", "gift.fill", "tag.fill", "creditcard.fill", "dollarsign.circle.fill", "chart.line.uptrend.xyaxis",
        "arrow.right.circle.fill", "arrow.left.circle.fill", "arrow.up.circle.fill", "arrow.down.circle.fill",
        "arrowshape.turn.up.right.fill", "hand.point.right.fill", "hand.point.left.fill", "hand.tap.fill", "eye.fill",
        "bubble.left.fill", "bubble.right.fill", "quote.bubble.fill", "phone.fill", "envelope.fill", "paperplane.fill",
        "link", "at", "number", "clock.fill", "alarm.fill", "calendar", "sun.max.fill", "moon.fill", "cloud.fill",
        "cloud.rain.fill", "snowflake", "leaf.fill", "drop.fill", "pawprint.fill", "fork.knife", "cup.and.saucer.fill",
        "gamecontroller.fill", "trophy.fill", "medal.fill", "flag.fill", "lightbulb.fill", "book.fill", "graduationcap.fill",
        "person.fill", "person.2.fill", "figure.walk", "figure.run", "sportscourt.fill", "dumbbell.fill", "heart.circle.fill",
        "face.smiling", "hands.clap.fill", "hand.wave.fill", "plus.circle.fill", "minus.circle.fill", "circle.fill",
        "square.fill", "triangle.fill", "diamond.fill", "hexagon.fill", "seal.fill", "rosette", "burst.fill"
    ]

    static let emojis: [String] = [
        "😀", "😂", "🥹", "😍", "🤩", "😎", "🤔", "😮", "😢", "😡", "🙏", "👏", "👍", "👎", "👀", "💪",
        "🔥", "✨", "⭐️", "💯", "❤️", "💛", "💚", "💙", "🎉", "🎁", "🎵", "📌", "📍", "✅", "❌", "⚠️",
        "💡", "📣", "🚀", "🏆", "🎯", "⏰", "📅", "☕️", "🌙", "☀️", "🌴", "🕋", "🇰🇼", "🇸🇦", "🇦🇪"
    ]
}
