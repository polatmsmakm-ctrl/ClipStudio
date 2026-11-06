//
//  PlatformPresetsView.swift
//  ClipStudio — Features/Stories (social media presets)
//
//  Editable platform presets. Upload limits change over time, so every value
//  (duration, file size, aspect, resolution, fps, codec, framing) is editable.
//

import SwiftUI

struct PlatformPresetsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                Label("حدود المنصات تتغير باستمرار — راجعها وعدّلها حسب حسابك.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(Theme.Palette.textSecondary)
            }
            .listRowBackground(Color.clear)

            Section("المنصات") {
                ForEach(env.presets.platforms) { preset in
                    NavigationLink(value: Route.presetEditor(preset.id)) {
                        HStack(spacing: 12) {
                            Image(systemName: preset.symbol).foregroundStyle(Theme.Palette.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.subheadline.weight(.semibold))
                                Text(summary(preset)).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                            }
                            Spacer()
                            if !preset.isBuiltIn { StatusPill(text: "مخصص") }
                        }
                    }
                    .swipeActions {
                        if !preset.isBuiltIn {
                            Button(role: .destructive) { env.presets.delete(preset.id) } label: { Label("حذف", systemImage: "trash") }
                        }
                    }
                }
            }
            .listRowBackground(Theme.Palette.surface.opacity(0.7))

            Section {
                Button {
                    let preset = env.presets.addCustom()
                    env.router.push(.presetEditor(preset.id))
                } label: { Label("إضافة منصة مخصصة", systemImage: "plus.circle.fill") }
                Button(role: .destructive) { confirmReset = true } label: { Label("استعادة القيم الافتراضية", systemImage: "arrow.counterclockwise") }
            }
            .listRowBackground(Theme.Palette.surface.opacity(0.7))
        }
        .screenBackground()
        .navigationTitle("منصات التواصل")
        .confirmationDialog("استعادة كل المنصات المدمجة لقيمها الافتراضية؟", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("استعادة", role: .destructive) { env.presets.resetAll() }
        }
    }

    private func summary(_ preset: PlatformPreset) -> String {
        var parts = [preset.aspect.title, preset.resolution.title]
        parts.append(preset.maxDuration.map { "≤ " + Fmt.seconds($0, digits: 0) } ?? "بدون حد")
        if let size = preset.maxFileSizeMB { parts.append("≤ " + Fmt.number(size) + " MB") }
        return parts.joined(separator: " • ")
    }
}

struct PresetEditorView: View {
    @Environment(AppEnvironment.self) private var env
    let presetID: UUID
    @State private var draft: PlatformPreset?

    private let symbols = ["camera.circle", "play.rectangle.on.rectangle", "music.note", "bubble.left.and.bubble.right",
                           "phone.bubble", "play.square.stack", "play.rectangle", "person.2", "xmark.square", "star",
                           "heart", "bolt", "globe", "sparkles"]

    var body: some View {
        Form {
            if let draft {
                Section("الاسم") {
                    TextField("اسم المنصة", text: binding(\.name))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(symbols, id: \.self) { symbol in
                                Button { update { $0.symbol = symbol } } label: {
                                    Image(systemName: symbol)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(draft.symbol == symbol ? Theme.Palette.accentSoft : Color.clear))
                                        .foregroundStyle(draft.symbol == symbol ? Theme.Palette.accent : Theme.Palette.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section("الحدود") {
                    Toggle("حد أقصى للمدة", isOn: Binding(get: { draft.maxDuration != nil },
                                                        set: { on in update { $0.maxDuration = on ? 60 : nil } }))
                    if draft.maxDuration != nil {
                        DecimalField(title: "المدة القصوى", value: Binding(get: { draft.maxDuration ?? 60 }, set: { v in update { $0.maxDuration = v } }),
                                     range: 1...7200, step: 5, digits: 0, unit: "ث")
                    }
                    Toggle("حد أقصى للحجم", isOn: Binding(get: { draft.maxFileSizeMB != nil },
                                                        set: { on in update { $0.maxFileSizeMB = on ? 100 : nil } }))
                    if draft.maxFileSizeMB != nil {
                        DecimalField(title: "الحجم الأقصى", value: Binding(get: { draft.maxFileSizeMB ?? 100 }, set: { v in update { $0.maxFileSizeMB = v } }),
                                     range: 1...10_000, step: 5, digits: 0, unit: "MB")
                    }
                }
                Section("الإطار والجودة") {
                    Picker("المقاس", selection: binding(\.aspect)) {
                        ForEach(AspectRatio.common) { Text($0.label).tag($0) }
                    }
                    Picker("الملاءمة", selection: binding(\.fitMode)) {
                        ForEach(FitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("الدقة", selection: binding(\.resolution)) {
                        ForEach(ResolutionPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("معدل الإطارات", selection: binding(\.frameRate)) {
                        ForEach(FrameRateOption.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("الترميز", selection: binding(\.codec)) {
                        ForEach(VideoCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("ملاحظات") {
                    TextField("ملاحظة", text: binding(\.notes), axis: .vertical)
                }
                if draft.isBuiltIn {
                    Section {
                        Button("استعادة القيم الافتراضية لهذه المنصة") {
                            env.presets.resetBuiltIn(draft.id)
                            self.draft = env.presets.platforms.first { $0.id == presetID }
                        }
                    }
                }
            }
        }
        .screenBackground()
        .navigationTitle(draft?.name ?? "منصة")
        .onAppear { draft = env.presets.platforms.first { $0.id == presetID } }
        .keyboardDoneToolbar()
    }

    private func update(_ change: (inout PlatformPreset) -> Void) {
        guard var value = draft else { return }
        change(&value)
        draft = value
        env.presets.save(value)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<PlatformPreset, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: keyPath] }, set: { newValue in update { $0[keyPath: keyPath] = newValue } })
    }
}
