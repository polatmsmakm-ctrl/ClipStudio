//
//  TemplatesWorkspaceView.swift
//  ClipStudio — Features/Templates (Part 4)
//
//  Templates workspace: projects saved as templates with numbered media slots.
//  Fill the slots with new photos / videos (one by one, or several in order) and a
//  new Pro Studio project is created with the template's timing, transitions,
//  color, titles, motion and music. SaveTemplateSheet saves the open project.
//  Part 4 suggestions: share a template as a .cstemplate file and import one.
//

import SwiftUI

struct TemplatesWorkspaceView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var library = StudioTemplateLibrary.shared
    @State private var search = ""
    @State private var filling: StudioTemplate?
    @State private var renaming: StudioTemplate?
    @State private var nameDraft = ""
    @State private var deleting: StudioTemplate?
    @State private var shareItem: ShareItem?
    @State private var showImporter = false

    private var templates: [StudioTemplate] {
        library.templates.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if library.templates.isEmpty {
                    EmptyStateView(systemImage: "square.grid.3x3.square", title: "لا توجد قوالب بعد",
                                   message: "افتح أي مشروع في الاستوديو ثم: القائمة ← «حفظ كقالب». تتحول اللقطات إلى خانات تملؤها بصور وفيديوهات جديدة.")
                } else if templates.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: "لا نتائج", message: "جرّب كلمة أخرى.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 260 : 220), spacing: 14)], spacing: 14) {
                        ForEach(templates) { template in
                            Button { filling = template } label: { TemplateCard(template: template) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { filling = template } label: { Label("استخدام القالب", systemImage: "square.and.pencil") }
                                    Button { nameDraft = template.name; renaming = template } label: { Label("إعادة تسمية", systemImage: "pencil") }
                                    Button { share(template) } label: { Label("مشاركة كملف", systemImage: "square.and.arrow.up") }
                                    Divider()
                                    Button(role: .destructive) { deleting = template } label: { Label("حذف", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("القوالب")
        .searchable(text: $search, prompt: "بحث في القوالب")
        .onAppear { library.reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("استيراد قالب", systemImage: "square.and.arrow.down") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: StyleSharing.importTypes) { result in
            guard case .success(let url) = result else { return }
            importFile(url)
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: item.urls) }
        .sheet(item: $filling) { template in
            TemplateFillSheet(template: template)
        }
        .alert("اسم القالب", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("الاسم", text: $nameDraft)
            Button("حفظ") {
                if let template = renaming { library.rename(template.id, to: nameDraft) }
                renaming = nil
            }
            Button("إلغاء", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleting.map { "حذف «" + $0.name + "»؟" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("حذف القالب", role: .destructive) {
                if let template = deleting { library.delete(template.id) }
                deleting = nil
            }
        } message: {
            Text("يُحذف القالب فقط — المشاريع التي أنشأتها منه والوسائط تبقى.")
        }
    }
}

extension TemplatesWorkspaceView {
    fileprivate func share(_ template: StudioTemplate) {
        do {
            shareItem = ShareItem(urls: [try StyleSharing.exportTemplate(template)])
        } catch {
            env.toasts.show(error.localizedDescription, style: .error)
        }
    }

    fileprivate func importFile(_ url: URL) {
        do {
            switch try StyleSharing.read(url) {
            case .template(let template):
                try library.add(template)
                Haptics.success()
                env.toasts.show("استُورد القالب «" + template.name + "» — املأ خاناته بوسائطك", style: .success)
            case .style(let dna):
                EditingDNAStore.shared.save(dna)
                env.toasts.show("هذا ملف أسلوب — أُضيف إلى أساليب المونتاج «" + dna.name + "»", style: .success)
            }
        } catch {
            env.toasts.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, style: .warning)
        }
    }
}

struct TemplateCard: View {
    @Environment(AppEnvironment.self) private var env
    let template: StudioTemplate

    private var coverAsset: MediaAsset? {
        for slot in template.slots.sorted(by: { $0.index < $1.index }) {
            if let clip = TimelineEngine.clip(slot.clipID, in: template.timeline),
               let id = clip.source.assetIDs.first, let asset = env.library.asset(id), !env.library.isMissing(asset) {
                return asset
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.Palette.surfaceRaised)
                if let asset = coverAsset {
                    MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 0.5), cornerRadius: Theme.Radius.md)
                } else {
                    Image(systemName: "square.grid.3x3.square")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            Text(template.name).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                StatusPill(text: Fmt.int(template.slots.count) + " خانة", systemImage: "square.grid.2x2")
                StatusPill(text: Fmt.duration(template.duration), color: Theme.Palette.textSecondary, systemImage: "clock")
                StatusPill(text: template.settings.aspect.title, color: Theme.Palette.textSecondary)
            }
            if !template.note.isEmpty {
                Text(template.note).font(.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(Theme.Palette.surface.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.Palette.stroke))
        }
    }
}

// MARK: - Fill slots → new project

struct TemplateFillSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let template: StudioTemplate

    @State private var name = ""
    @State private var assignments: [UUID: MediaAsset] = [:]
    @State private var picking: TemplateSlot?
    @State private var pickingMany = false

    private var slots: [TemplateSlot] { template.slots.sorted { $0.index < $1.index } }

    var body: some View {
        NavigationStack {
            Form {
                Section("اسم المشروع الجديد") {
                    TextField(template.name, text: $name)
                        .submitLabel(.done)
                }
                Section {
                    Button { pickingMany = true } label: {
                        Label("اختر عدة ملفات بالترتيب", systemImage: "rectangle.stack.badge.plus")
                    }
                    if !assignments.isEmpty {
                        Button(role: .destructive) { assignments = [:] } label: { Label("تفريغ كل الخانات", systemImage: "xmark.circle") }
                    }
                } footer: {
                    Text("تُملأ الخانات الفارغة بالترتيب. الخانة الفارغة تُحذف من المشروع، والفيديو الأقصر من الخانة يُبطأ ليحافظ على الإيقاع.")
                }
                Section("الخانات (" + Fmt.int(assignments.count) + "/" + Fmt.int(slots.count) + ")") {
                    ForEach(slots) { slot in
                        Button { picking = slot } label: { slotRow(slot) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                if assignments[slot.clipID] != nil {
                                    Button(role: .destructive) { assignments[slot.clipID] = nil } label: { Label("تفريغ", systemImage: "xmark") }
                                }
                            }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle(template.name)
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إنشاء") { create() }
                        .fontWeight(.semibold)
                        .disabled(assignments.isEmpty)
                }
            }
            .sheet(item: $picking) { slot in
                MediaPickerSheet(title: "الخانة " + Fmt.int(slot.index), kinds: [.video, .image], allowsMultiple: false,
                                 confirmTitle: "وضع") { assets in
                    if let asset = assets.first { assignments[slot.clipID] = asset }
                }
            }
            .sheet(isPresented: $pickingMany) {
                MediaPickerSheet(title: "ملء الخانات", kinds: [.video, .image], allowsMultiple: true, confirmTitle: "ملء") { assets in
                    var queue = assets
                    for slot in slots where assignments[slot.clipID] == nil {
                        guard !queue.isEmpty else { break }
                        assignments[slot.clipID] = queue.removeFirst()
                    }
                }
            }
        }
    }

    private func slotRow(_ slot: TemplateSlot) -> some View {
        HStack(spacing: 12) {
            Text(Fmt.int(slot.index))
                .font(.headline.monospacedDigit())
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.Palette.accentSoft))
                .foregroundStyle(Theme.Palette.accent)
            if let asset = assignments[slot.clipID] {
                MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 0.5))
                    .frame(width: 64, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.displayName).font(.subheadline).lineLimit(1)
                    Text(asset.kind == .image ? "صورة" : asset.durationText)
                        .font(.caption)
                        .foregroundStyle(asset.kind == .video && (asset.durationSeconds ?? 0) + 0.01 < slot.duration
                                         ? Theme.Palette.warning : Theme.Palette.textSecondary)
                }
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.Palette.stroke, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .frame(width: 64, height: 40)
                    .overlay(Image(systemName: "plus").foregroundStyle(Theme.Palette.textTertiary))
                Text("فارغة").font(.subheadline).foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
            Text(Fmt.seconds(slot.duration, digits: 1))
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private func create() {
        var durations: [UUID: Double] = [:]
        for asset in env.library.assets { if let seconds = asset.durationSeconds { durations[asset.id] = seconds } }
        let context = EditContext(assetDurations: durations, frameRate: Double(template.settings.frameRate), magnetic: true)
        let available = Set(env.library.assets.filter { !env.library.isMissing($0) }.map(\.id))
        var report = TemplateFillReport()
        let timeline = StudioTemplateLibrary.fill(template, assignments: assignments, available: available,
                                                  context: context, report: &report)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = env.projects.create(kind: .pro, name: trimmed.isEmpty ? template.name : trimmed,
                                          settings: template.settings) { project in
            project.timeline = timeline
            project.markers = template.markers
            project.coverAssetID = assignments.values.first?.id
        }
        var text = "أُنشئ المشروع"
        if report.slowed > 0 { text += " • " + Fmt.int(report.slowed) + " فيديو أُبطئ" }
        if report.removedEmpty > 0 { text += " • حُذفت " + Fmt.int(report.removedEmpty) + " خانة فارغة" }
        if report.droppedMissingAudio > 0 { text += " • موسيقى القالب مفقودة" }
        env.toasts.show(text, style: .success, duration: 3)
        Haptics.success()
        dismiss()
        env.router.openStudio(project.id)
    }
}

// MARK: - Save the open project as a template

struct SaveTemplateSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    @State private var keepAudio = true

    private var slotCount: Int {
        vm.project.timeline.tracks.filter { $0.kind == .video || $0.kind == .overlay }.flatMap(\.clips).filter { clip in
            switch clip.source {
            case .media, .image, .freezeFrame: true
            default: false
            }
        }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("الاسم") {
                    TextField(vm.project.name, text: $name)
                        .submitLabel(.done)
                    TextField("وصف قصير (اختياري)", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section {
                    Toggle("احتفظ بالموسيقى والأصوات", isOn: $keepAudio)
                    LabeledContent("الخانات", value: Fmt.int(slotCount))
                } footer: {
                    Text("كل صورة أو فيديو على مسارات الصورة يصير خانة. التوقيت والانتقالات والألوان والنصوص والحركة تبقى كما هي.")
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("حفظ كقالب")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        vm.saveAsTemplate(name: name, note: note, keepAudio: keepAudio)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(slotCount == 0)
                }
            }
        }
    }
}
