//
//  StudioHubView.swift
//  ClipStudio — Features/ProStudio
//
//  Pro Studio home: Pro projects (open, duplicate, rename, delete), new project
//  with canvas / resolution / frame-rate presets and optional starting media, and
//  conversion of Smart Stories / Smart Merge projects into editable timelines.
//  Part 4: shortcuts to the Templates workspace, the Editing DNA library and the
//  beat auto-edit.
//

import SwiftUI

struct StudioHubView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showNew = false
    @State private var showAutoEdit = false
    @State private var search = ""
    @State private var renaming: ProjectSummary?
    @State private var nameDraft = ""
    @State private var deleting: ProjectSummary?

    private var proProjects: [ProjectSummary] {
        env.projects.summaries.filter { $0.kind == .pro }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var convertible: [ProjectSummary] {
        env.projects.summaries.filter { $0.kind != .pro }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 220 : 200), spacing: 14)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                hero
                intelligenceRow
                if proProjects.isEmpty && search.isEmpty {
                    EmptyStateView(systemImage: "film.stack", title: "ابدأ مشروعك الاحترافي",
                                   message: "خط زمني متعدد المسارات، إطارات مفتاحية، تصحيح ألوان، أقنعة، كروما، سرعات ومنحنيات، وتسلسلات متداخلة.",
                                   actionTitle: "مشروع جديد") { showNew = true }
                } else {
                    SectionTitle(title: "مشاريع الاستوديو", subtitle: Fmt.int(proProjects.count) + " مشروع", systemImage: "film.stack")
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(proProjects) { summary in
                            Button { env.router.openStudio(summary.id) } label: {
                                ProjectCard(summary: summary)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { env.router.openStudio(summary.id) } label: { Label("فتح", systemImage: "arrow.up.forward.app") }
                                Button { nameDraft = summary.name; renaming = summary } label: { Label("إعادة تسمية", systemImage: "pencil") }
                                Button {
                                    if let copy = env.projects.duplicate(summary.id) {
                                        env.toasts.show("تم إنشاء نسخة: " + copy.name, style: .success)
                                    }
                                } label: { Label("نسخة مكررة", systemImage: "plus.square.on.square") }
                                Button { env.router.push(.versions(summary.id)) } label: { Label("سجل الإصدارات", systemImage: "clock.arrow.circlepath") }
                                Divider()
                                Button(role: .destructive) { deleting = summary } label: { Label("حذف", systemImage: "trash") }
                            }
                        }
                    }
                }
                if !convertible.isEmpty {
                    convertSection
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("الاستوديو")
        .searchable(text: $search, prompt: "بحث في المشاريع")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNew = true } label: { Label("مشروع جديد", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showNew) {
            NewStudioProjectSheet { id in env.router.openStudio(id) }
        }
        .sheet(isPresented: $showAutoEdit) {
            BeatAutoEditSheet()
        }
        .alert("اسم المشروع", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("الاسم", text: $nameDraft)
            Button("حفظ") {
                if let summary = renaming { env.projects.rename(summary.id, to: nameDraft) }
                renaming = nil
            }
            Button("إلغاء", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleting.map { "حذف «" + $0.name + "»؟" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("حذف المشروع", role: .destructive) {
                if let summary = deleting { env.projects.delete(summary.id) }
                deleting = nil
            }
        } message: {
            Text("يُحذف المشروع وإصداراته فقط — الوسائط والملفات المصدّرة تبقى.")
        }
    }

    private var hero: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: "film.stack")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.Palette.accentSoft))
                VStack(alignment: .leading, spacing: 4) {
                    Text("الاستوديو الاحترافي").font(.title3.weight(.bold))
                    Text("مونتاج متعدد المسارات بمعالجة GPU — ما تراه هو ما يُصدَّر.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Button { showNew = true } label: { Label("جديد", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var intelligenceRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 240 : 160), spacing: 12)], spacing: 12) {
            ToolTile(title: "القوالب", subtitle: Fmt.int(StudioTemplateLibrary.shared.templates.count) + " قالب — املأ الخانات بوسائط جديدة",
                     systemImage: "square.grid.3x3.square") {
                env.router.push(.templates)
            }
            ToolTile(title: "أساليب المونتاج", subtitle: "إيقاع وألوان ونصوص قابلة لإعادة الاستخدام", systemImage: "dna") {
                env.router.push(.editingStyles)
            }
            ToolTile(title: "مونتاج تلقائي على الإيقاع", subtitle: "صور وفيديوهات + أغنية + أسلوب ← مشروع جاهز",
                     systemImage: "metronome") {
                showAutoEdit = true
            }
        }
    }

    private var convertSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "افتح مشروعًا آخر في الاستوديو", subtitle: "تُنشأ نسخة احترافية قابلة للتعديل ويبقى الأصل كما هو",
                         systemImage: "arrow.triangle.branch")
            ForEach(convertible.prefix(12)) { summary in
                HStack(spacing: 12) {
                    Image(systemName: summary.kind.symbol).foregroundStyle(Theme.Palette.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(summary.kind.title + " • " + Fmt.duration(summary.durationSeconds))
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    Button("تحويل") {
                        if let id = ProjectActions.convertToPro(summary, env: env) {
                            env.router.openStudio(id)
                        } else {
                            env.toasts.show("تعذّر التحويل — تحقق من وجود الوسائط.", style: .warning)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Palette.surface.opacity(0.7)))
            }
        }
    }
}

// MARK: - New project

struct NewStudioProjectSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onCreated: (UUID) -> Void

    @State private var name = ""
    @State private var aspect: AspectRatio = .landscape16x9
    @State private var shortSide = 1080
    @State private var frameRate = 30
    @State private var picked: [MediaAsset] = []
    @State private var showPicker = false
    @State private var matchFirst = true
    @State private var template: ProjectTemplate = .blank
    @State private var openingTitle = ""

    private var size: CGSize { aspect.canvasSize(shortSide: shortSide) }

    var body: some View {
        NavigationStack {
            Form {
                Section("الاسم") {
                    TextField("مشروع جديد", text: $name)
                        .submitLabel(.done)
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ProjectTemplate.allCases) { option in
                                templateTile(option)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if template != .blank {
                        TextField("عنوان افتتاحي (اختياري)", text: $openingTitle)
                            .submitLabel(.done)
                    }
                } header: {
                    Text("القالب")
                } footer: {
                    Text(template.subtitle)
                }
                Section("اللوحة") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AspectRatio.common) { option in
                                ChipButton(title: option.label, isSelected: option == aspect) {
                                    aspect = option
                                    matchFirst = false
                                }
                            }
                        }
                    }
                    Picker("الدقة", selection: $shortSide) {
                        Text("720p").tag(720)
                        Text("1080p").tag(1080)
                        Text("1440p").tag(1440)
                        Text("4K").tag(2160)
                    }
                    Picker("معدل الإطارات", selection: $frameRate) {
                        ForEach([24, 25, 30, 50, 60], id: \.self) { Text(Fmt.int($0) + " fps").tag($0) }
                    }
                    HStack {
                        Text("المقاس")
                        Spacer()
                        Text(Fmt.resolution(Int(size.width), Int(size.height))).font(Theme.Typo.mono)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Section {
                    Button { showPicker = true } label: {
                        Label(picked.isEmpty ? "اختيار وسائط للبدء (اختياري)" : "تم اختيار " + Fmt.int(picked.count) + " ملف",
                              systemImage: "photo.on.rectangle.angled")
                    }
                    if !picked.isEmpty {
                        Toggle("مطابقة اللوحة مع أول فيديو", isOn: $matchFirst)
                            .tint(Theme.Palette.accent)
                    }
                } footer: {
                    Text("تُوضع الفيديوهات والصور بالترتيب على المسار الرئيسي والصوت على مسار الصوت.")
                }
            }
            .screenBackground()
            .navigationTitle("مشروع احترافي جديد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("إنشاء", action: create).fontWeight(.semibold) }
            }
            .sheet(isPresented: $showPicker) {
                MediaPickerSheet(title: "وسائط المشروع", kinds: [.video, .image, .audio], allowsMultiple: true, confirmTitle: "إضافة") { assets in
                    picked = assets
                    if let first = assets.first(where: { $0.kind == .video }), let w = first.pixelWidth, let h = first.pixelHeight, matchFirst {
                        aspect = .reduced(width: w, height: h)
                        shortSide = min(max(min(w, h), 720), 2160)
                        if let fps = first.frameRate { frameRate = [24, 25, 30, 50, 60].min { abs(Double($0) - fps) < abs(Double($1) - fps) } ?? 30 }
                    }
                }
            }
            .keyboardDoneToolbar()
        }
    }

    private func templateTile(_ option: ProjectTemplate) -> some View {
        Button {
            template = option
            if let preset = option.aspect {
                aspect = preset
                matchFirst = false
            }
            Haptics.selection()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 54, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(option == template ? Theme.Palette.accent : Theme.Palette.surfaceHighlight))
                    .foregroundStyle(option == template ? Color(hex: 0x1A1408) : Theme.Palette.textPrimary)
                Text(option.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(option == template ? Theme.Palette.accent : Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 84)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("قالب " + option.title)
        .accessibilityAddTraits(option == template ? .isSelected : [])
    }

    private func create() {
        var settings = ProjectSettings(aspect: aspect, shortSide: shortSide, frameRate: frameRate)
        if matchFirst, let first = picked.first(where: { $0.kind == .video }), let w = first.pixelWidth, let h = first.pixelHeight {
            let scale = Double(shortSide) / Double(max(1, min(w, h)))
            settings = ProjectSettings(canvasWidth: Int(ExportGeometry.even(CGFloat(Double(w) * scale))),
                                       canvasHeight: Int(ExportGeometry.even(CGFloat(Double(h) * scale))),
                                       frameRate: frameRate)
        }
        let id = ProjectActions.newPro(name: name, settings: settings, assets: picked,
                                       imageDuration: env.studioPrefs.defaultImageDuration,
                                       template: template, openingTitle: template == .blank ? "" : openingTitle, env: env)
        dismiss()
        onCreated(id)
    }
}
