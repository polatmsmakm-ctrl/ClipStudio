//
//  EditingDNASheet.swift
//  ClipStudio — Features/Intelligence (Part 4)
//
//  Editing DNA in the editor: pick a style (built-in, learned from a project or
//  from a reference video), choose which parts to apply, apply as one undo step.
//  Also: learn the current project's style, or a reference video's (analyzed on
//  device, never imported or uploaded). EditingStylesView manages the library
//  from the Studio hub / Settings. Part 5: optional Gemini enrichment of a
//  learned reference style (after consent).
//

import SwiftUI
import UniformTypeIdentifiers

struct EditingDNASheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var store = EditingDNAStore.shared
    @State private var selectedID: UUID?
    @State private var options = DNAApplyOptions()
    @State private var naming: DNANamingPurpose?
    @State private var nameDraft = ""
    @State private var pendingReference: URL?
    @State private var showFileImporter = false
    @State private var showLibraryPicker = false
    @State private var renaming: EditingDNA?
    @State private var deleting: EditingDNA?
    @State private var consent: AIConsentRequest?

    private var selected: EditingDNA? { selectedID.flatMap(store.style) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("أسلوب المونتاج = إيقاع اللقطات، الانتقالات، الألوان، شكل النصوص والترجمة، حركة الصور ومستوى الموسيقى. طبّقه على مشروعك بخطوة تراجع واحدة.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    SectionTitle(title: "الأساليب", subtitle: Fmt.int(store.all.count) + " أسلوب", systemImage: "dna")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(store.all) { dna in
                            EditingDNACard(dna: dna, isSelected: dna.id == selectedID) {
                                selectedID = dna.id
                                Haptics.selection()
                            }
                            .contextMenu { contextMenu(dna) }
                        }
                    }
                    if let selected {
                        optionsCard(selected)
                    }
                }
                .padding(Theme.Space.md)
            }
            .screenBackground()
            .studioBusyOverlay(vm)
            .navigationTitle("أسلوب المونتاج")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { nameDraft = vm.project.name; naming = .project } label: {
                            Label("تعلّم أسلوب هذا المشروع", systemImage: "film.stack")
                        }
                        Button { showFileImporter = true } label: {
                            Label("من فيديو مرجعي (الملفات)", systemImage: "folder")
                        }
                        Button { showLibraryPicker = true } label: {
                            Label("من فيديو مرجعي (المكتبة)", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        Label("تعلّم أسلوبًا", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
                if case .success(let url) = result {
                    pendingReference = url
                    nameDraft = url.deletingPathExtension().lastPathComponent
                    naming = .reference
                }
            }
            .sheet(isPresented: $showLibraryPicker) {
                MediaPickerSheet(title: "فيديو مرجعي", kinds: [.video], allowsMultiple: false, confirmTitle: "تحليل") { assets in
                    if let asset = assets.first {
                        pendingReference = vm.env.library.url(for: asset)
                        nameDraft = asset.displayName
                        naming = .reference
                    }
                }
            }
            .alert("اسم الأسلوب", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("الاسم", text: $nameDraft)
                Button("حفظ") { learn() }
                Button("إلغاء", role: .cancel) { naming = nil; pendingReference = nil }
            } message: {
                Text(naming == .reference ? "يُحلل الفيديو على جهازك فقط — لا يُنسخ ولا يُرفع." : "يُحفظ إيقاع وألوان ونصوص المشروع كأسلوب قابل لإعادة الاستخدام.")
            }
            .alert("إعادة تسمية", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("الاسم", text: $nameDraft)
                Button("حفظ") {
                    if let dna = renaming { store.rename(dna.id, to: nameDraft) }
                    renaming = nil
                }
                Button("إلغاء", role: .cancel) { renaming = nil }
            }
            .aiConsent($consent)
            .aiConsent($consent)
        .confirmationDialog(deleting.map { "حذف «" + $0.name + "»؟" } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("حذف", role: .destructive) {
                    if let dna = deleting {
                        store.delete(dna.id)
                        if selectedID == dna.id { selectedID = nil }
                    }
                    deleting = nil
                }
            }
            .onAppear {
                if selectedID == nil { selectedID = store.all.first?.id }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ dna: EditingDNA) -> some View {
        Button { store.duplicate(dna.id) } label: { Label("نسخة قابلة للتعديل", systemImage: "plus.square.on.square") }
        if !dna.isBuiltIn {
            Button { nameDraft = dna.name; renaming = dna } label: { Label("إعادة تسمية", systemImage: "pencil") }
            Button(role: .destructive) { deleting = dna } label: { Label("حذف", systemImage: "trash") }
        }
    }

    private func optionsCard(_ dna: EditingDNA) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "ماذا تطبّق من «" + dna.name + "»؟", systemImage: "checklist")
                Toggle("إيقاع اللقطات (" + Fmt.seconds(dna.averageShotLength, digits: 1) + " للقطة)" + (dna.cutsOnBeat ? " على الإيقاع" : ""),
                       isOn: $options.pacing)
                Toggle("الانتقالات" + (dna.transitionKind.map { " (" + $0.title + ")" } ?? " (قطع مباشر)"), isOn: $options.transitions)
                Toggle(dna.referenceFrame != nil ? "مطابقة الألوان مع الإطار المرجعي" : "الألوان", isOn: $options.color)
                    .disabled(dna.color == nil && dna.lut == nil && dna.referenceFrame == nil)
                if options.color, dna.referenceFrame != nil {
                    PrecisionSlider(title: "قوة المطابقة", value: $options.colorStrength, range: 0.2...1, defaultValue: 0.85, step: 0.05,
                                    format: { Fmt.percent($0) })
                }
                Toggle("أنماط النصوص والترجمة", isOn: $options.text)
                    .disabled(dna.captionStyle == nil && dna.titleStyle == nil)
                Toggle("حركة هادئة للصور", isOn: $options.stillMotion)
                    .disabled(!dna.stillMotion)
                Toggle("مستوى الموسيقى" + (dna.musicVolume.map { " (" + Fmt.percent($0) + ")" } ?? ""), isOn: $options.music)
                    .disabled(dna.musicVolume == nil)
                if options.pacing {
                    Text("إيقاع اللقطات يقصّر المقاطع الطويلة على المسار الرئيسي (من بدايتها). تقدر تتراجع بخطوة واحدة.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Button {
                    vm.applyDNA(dna, options: options)
                    dismiss()
                } label: {
                    Label("طبّق الأسلوب", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.csPrimary)
                .disabled(vm.timeline.isEmpty)
            }
        }
    }

    private func learn() {
        let name = nameDraft
        switch naming {
        case .project:
            selectedID = vm.learnDNAFromProject(name: name).id
        case .reference:
            if let url = pendingReference {
                vm.learnDNA(fromReference: url, name: name) { dna in
                    guard let dna else { return }
                    selectedID = dna.id
                    offerStyleEnrichment(dna, url: url, env: vm.env, present: { consent = $0 }) { enriched in
                        selectedID = enriched.id
                    }
                }
            }
        case nil:
            break
        }
        naming = nil
        pendingReference = nil
    }
}

enum DNANamingPurpose: Hashable {
    case project, reference
}

// MARK: - Card

struct EditingDNACard: View {
    let dna: EditingDNA
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: dna.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.Palette.accentSoft))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dna.name).font(.headline).lineLimit(1)
                        Text(dna.isBuiltIn ? "أسلوب جاهز" : dna.origin)
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let data = dna.referenceFrame, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                Text(dna.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let aspect = dna.aspect {
                    StatusPill(text: aspect.label, color: Theme.Palette.textSecondary, systemImage: "aspectratio")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isSelected ? Theme.Palette.accentSoft : Theme.Palette.surface.opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(isSelected ? Theme.Palette.accent : Theme.Palette.stroke, lineWidth: isSelected ? 1.5 : 1))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Library (hub / settings)

struct EditingStylesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var store = EditingDNAStore.shared
    @State private var showFileImporter = false
    @State private var showLibraryPicker = false
    @State private var pendingReference: URL?
    @State private var pendingScoped = false
    @State private var nameDraft = ""
    @State private var askName = false
    @State private var renaming: EditingDNA?
    @State private var deleting: EditingDNA?
    @State private var consent: AIConsentRequest?
    @State private var progress: Double?
    @State private var control: RenderControl?
    @State private var search = ""
    @State private var shareItem: ShareItem?
    @State private var showStyleImporter = false

    private var styles: [EditingDNA] {
        store.all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "أساليب المونتاج", subtitle: "تُطبّق من داخل الاستوديو: القائمة ← أسلوب المونتاج",
                                     systemImage: "dna")
                        Text("تعلّم أسلوب أي فيديو مرجعي (إيقاع القطع، الإضاءة والألوان، وجود نصوص، سرعة الموسيقى) — التحليل على جهازك ولا يُحفظ من الفيديو إلا صورة صغيرة للألوان.")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        if let progress {
                            HStack {
                                ProgressBarView(progress: progress)
                                Button("إلغاء") { control?.cancel() }.font(.caption)
                            }
                        }
                    }
                }
                if styles.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: "لا نتائج", message: "جرّب كلمة أخرى.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                        ForEach(styles) { dna in
                            EditingDNACard(dna: dna) {}
                                .contextMenu {
                                    Button { store.duplicate(dna.id) } label: { Label("نسخة", systemImage: "plus.square.on.square") }
                                    Button { share(dna) } label: { Label("مشاركة كملف", systemImage: "square.and.arrow.up") }
                                    if !dna.isBuiltIn {
                                        Button { nameDraft = dna.name; renaming = dna } label: { Label("إعادة تسمية", systemImage: "pencil") }
                                        Button(role: .destructive) { deleting = dna } label: { Label("حذف", systemImage: "trash") }
                                    }
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
        .navigationTitle("أساليب المونتاج")
        .searchable(text: $search, prompt: "بحث")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showFileImporter = true } label: { Label("من الملفات", systemImage: "folder") }
                    Button { showLibraryPicker = true } label: { Label("من مكتبة الوسائط", systemImage: "photo.on.rectangle") }
                    Divider()
                    Button { showStyleImporter = true } label: { Label("استيراد ملف أسلوب (.csstyle)", systemImage: "square.and.arrow.down") }
                } label: {
                    Label("تعلّم من فيديو", systemImage: "plus")
                }
                .disabled(progress != nil)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result {
                pendingReference = url
                pendingScoped = true
                nameDraft = url.deletingPathExtension().lastPathComponent
                askName = true
            }
        }
        .sheet(isPresented: $showLibraryPicker) {
            MediaPickerSheet(title: "فيديو مرجعي", kinds: [.video], allowsMultiple: false, confirmTitle: "تحليل") { assets in
                if let asset = assets.first {
                    pendingReference = env.library.url(for: asset)
                    pendingScoped = false
                    nameDraft = asset.displayName
                    askName = true
                }
            }
        }
        .background {
            Color.clear
                .fileImporter(isPresented: $showStyleImporter, allowedContentTypes: StyleSharing.importTypes) { result in
                    guard case .success(let url) = result else { return }
                    importStyle(url)
                }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: item.urls) }
        .alert("اسم الأسلوب", isPresented: $askName) {
            TextField("الاسم", text: $nameDraft)
            Button("تحليل") { learn() }
            Button("إلغاء", role: .cancel) { pendingReference = nil }
        }
        .alert("إعادة تسمية", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("الاسم", text: $nameDraft)
            Button("حفظ") {
                if let dna = renaming { store.rename(dna.id, to: nameDraft) }
                renaming = nil
            }
            Button("إلغاء", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleting.map { "حذف «" + $0.name + "»؟" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                if let dna = deleting { store.delete(dna.id) }
                deleting = nil
            }
        }
    }

    private func share(_ dna: EditingDNA) {
        do {
            shareItem = ShareItem(urls: [try StyleSharing.exportStyle(dna)])
        } catch {
            env.toasts.show(error.localizedDescription, style: .error)
        }
    }

    private func importStyle(_ url: URL) {
        do {
            switch try StyleSharing.read(url) {
            case .style(let dna):
                store.save(dna)
                Haptics.success()
                env.toasts.show("استُورد الأسلوب «" + dna.name + "»", style: .success)
            case .template(let template):
                try StudioTemplateLibrary.shared.add(template)
                env.toasts.show("هذا ملف قالب — أُضيف إلى القوالب «" + template.name + "»", style: .success)
            }
        } catch {
            env.toasts.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, style: .warning)
        }
    }

    private func learn() {
        guard let url = pendingReference else { return }
        let scoped = pendingScoped
        let name = nameDraft
        let control = RenderControl()
        self.control = control
        progress = 0
        let relay = ProgressRelay { value in progress = value }
        Task {
            let accessing = scoped && url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let dna = try await ReferenceAnalyzer.analyze(url: url, name: name, control: control, progress: { relay.send($0) })
                store.save(dna)
                Haptics.success()
                env.toasts.show("حُفظ الأسلوب «" + dna.name + "»", style: .success)
                offerStyleEnrichment(dna, url: url, env: env, present: { consent = $0 }) { _ in }
            } catch {
                if !control.isCancelled {
                    env.toasts.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, style: .warning)
                }
            }
            progress = nil
            self.control = nil
            pendingReference = nil
        }
    }
}

// MARK: - Part 5: AI enrichment of a learned style

/// After a reference video is learned locally, offers to refine the style with
/// Gemini (8 small frames): transitions, caption look and color description.
@MainActor
func offerStyleEnrichment(_ dna: EditingDNA, url: URL, env: AppEnvironment, present: (AIConsentRequest) -> Void,
                          done: @escaping (EditingDNA) -> Void) {
    guard AISettings.shared.cloudAvailable else { return }
    withAIConsent(task: .styleEnrichment, sendsMedia: true,
                  summary: AIFeatureService.uploadSummary(frames: 8, hasText: false, videoSeconds: nil)
                      + "\nلتحسين الأسلوب (الانتقالات، شكل الترجمة، الألوان).",
                  present: present) { forceLocal in
        guard !forceLocal else { return }
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let enriched = try await AIFeatureService.enrich(dna, referenceURL: url)
                EditingDNAStore.shared.save(enriched)
                Haptics.success()
                env.toasts.show("حُسّن الأسلوب «" + enriched.name + "» بالذكاء الاصطناعي", style: .success)
                done(enriched)
            } catch {
                env.toasts.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, style: .warning)
            }
        }
    }
}
