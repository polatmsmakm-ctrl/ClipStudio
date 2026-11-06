//
//  MediaBrowserView.swift
//  ClipStudio — Features/Media (MediaLibrary UI)
//
//  Library grid with search, filters, sorting, import, details, rename,
//  relink missing files and safe deletion (warns when used by projects).
//

import SwiftUI
import UniformTypeIdentifiers

struct MediaBrowserView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var search = ""
    @State private var filter: MediaFilter = .all
    @State private var sort: MediaSort = .newest
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var detailAsset: MediaAsset?
    @State private var renameTarget: MediaAsset?
    @State private var renameText = ""
    @State private var deleteTarget: MediaAsset?
    @State private var relinkTarget: MediaAsset?
    @State private var showRelinkImporter = false

    private var visible: [MediaAsset] {
        let filtered = env.library.assets.filter { asset in
            filter.matches(asset, missing: env.library.isMissing(asset)) &&
                (search.isEmpty || asset.displayName.localizedCaseInsensitiveContains(search) ||
                    asset.originalFilename.localizedCaseInsensitiveContains(search))
        }
        return sort.sorted(filtered)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MediaFilter.allCases) { item in
                            ChipButton(title: item.title, isSelected: filter == item) { filter = item }
                        }
                    }
                }
                HStack {
                    Text(Fmt.int(env.library.assets.count) + " ملف • " + Fmt.bytes(env.library.totalBytes))
                        .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                }
                ImportProgressCard(importer: env.importer)

                if visible.isEmpty {
                    if env.library.assets.isEmpty {
                        EmptyStateView(systemImage: "photo.on.rectangle.angled", title: "مكتبة الوسائط فارغة",
                                       message: "استورد الفيديوهات والصور والصوتيات من مكتبة الصور أو من تطبيق الملفات. الملفات الأصلية لا تُعدَّل أبداً.",
                                       actionTitle: "استيراد من الصور") { showPhotos = true }
                    } else {
                        EmptyStateView(systemImage: "magnifyingglass", title: "لا نتائج", message: "جرّب كلمة بحث أو فلتراً آخر.")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 18) {
                        ForEach(visible) { asset in
                            MediaCell(asset: asset)
                                .onTapGesture { detailAsset = asset }
                                .contextMenu { contextMenu(for: asset) }
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
            .animation(.snappy, value: visible.map(\.id))
            .fileImporter(isPresented: $showRelinkImporter, allowedContentTypes: MediaImportManager.fileTypes) { result in
                relink(result)
            }
        }
        .searchable(text: $search, prompt: "بحث في الوسائط")
        .screenBackground()
        .navigationTitle("الوسائط")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ImportMenu(showPhotos: $showPhotos, showFiles: $showFiles) }
            ToolbarItem(placement: .secondaryAction) {
                Picker("الترتيب", selection: $sort) {
                    ForEach(MediaSort.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .mediaImport(showPhotos: $showPhotos, showFiles: $showFiles)
        .sheet(item: $detailAsset) { asset in
            MediaDetailView(asset: asset)
        }
        .alert("إعادة تسمية", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") {
                if let target = renameTarget { env.library.rename(target.id, to: renameText) }
                renameTarget = nil
            }
            Button("إلغاء", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("حذف من المكتبة؟", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("حذف نسخة ClipStudio", role: .destructive) {
                if let target = deleteTarget {
                    env.library.delete(target.id)
                    env.toasts.show("تم الحذف من المكتبة", style: .success)
                }
                deleteTarget = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .onAppear { env.library.refreshMissing() }
        .keyboardDoneToolbar()
    }

    private var deleteMessage: String {
        guard let target = deleteTarget else { return "" }
        let users = env.projects.projectsUsing(assetID: target.id)
        let base = "يُحذف الملف المنسوخ داخل التطبيق فقط — الأصل في الصور أو الملفات لا يتأثر."
        if users.isEmpty { return base }
        return base + "\nتنبيه: مستخدم في " + Fmt.int(users.count) + " مشروع: " + users.prefix(3).map(\.name).joined(separator: "، ")
    }

    @ViewBuilder
    private func contextMenu(for asset: MediaAsset) -> some View {
        Button { detailAsset = asset } label: { Label("التفاصيل", systemImage: "info.circle") }
        if asset.kind == .video {
            Button {
                let id = ProjectActions.newStory(asset: asset, env: env)
                env.router.select(.stories)
                env.router.push(.story(id))
            } label: { Label("قصة ذكية من هذا الفيديو", systemImage: "scissors") }
        }
        Button {
            renameText = asset.displayName
            renameTarget = asset
        } label: { Label("إعادة تسمية", systemImage: "pencil") }
        if env.library.isMissing(asset) {
            Button {
                relinkTarget = asset
                showRelinkImporter = true
            } label: { Label("ربط ملف بديل", systemImage: "link") }
        }
        Button(role: .destructive) { deleteTarget = asset } label: { Label("حذف", systemImage: "trash") }
    }

    private func relink(_ result: Result<URL, Error>) {
        guard let target = relinkTarget else { return }
        relinkTarget = nil
        switch result {
        case .success(let url):
            Task {
                do {
                    let staged = try await env.importer.stageForRelink(url)
                    try await env.library.relink(target.id, stagedFile: staged)
                    env.toasts.show("تم ربط الملف وإعادة توصيل المشاريع", style: .success)
                } catch {
                    env.toasts.show(error.localizedDescription, style: .error)
                }
            }
        case .failure(let error):
            env.toasts.show(error.localizedDescription, style: .error)
        }
    }
}

struct MediaDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let asset: MediaAsset
    @State private var player = PlayerController()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Group {
                        if asset.kind == .image {
                            MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 0), contentMode: .fit)
                        } else {
                            VideoPreview(controller: player)
                        }
                    }
                    .frame(maxHeight: 420)
                    .aspectRatio(asset.kind == .audio ? 16 / 6 : CGFloat(Double(asset.pixelWidth ?? 16) / Double(max(1, asset.pixelHeight ?? 9))),
                                 contentMode: .fit)

                    GlassCard {
                        VStack(spacing: 10) {
                            row("النوع", asset.kind.title)
                            if asset.kind != .image { row("المدة", asset.durationText) }
                            if asset.kind != .audio { row("الدقة", asset.resolutionText) }
                            if let fps = asset.frameRate { row("معدل الإطارات", Fmt.fps(fps)) }
                            if let codec = asset.videoCodec { row("ترميز الفيديو", codec) }
                            if let codec = asset.audioCodec { row("ترميز الصوت", codec) }
                            if let bitrate = asset.estimatedBitrate { row("معدل البت", Fmt.bitrate(bitrate)) }
                            row("الحجم", Fmt.bytes(asset.fileSize))
                            row("الاسم الأصلي", asset.originalFilename)
                            row("تاريخ الاستيراد", Fmt.date(asset.importedAt))
                        }
                    }

                    let users = env.projects.projectsUsing(assetID: asset.id)
                    if !users.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionTitle(title: "مستخدم في", systemImage: "folder")
                                ForEach(users) { summary in
                                    Label(summary.name, systemImage: summary.kind.symbol).font(.subheadline)
                                }
                            }
                        }
                    }

                    if asset.kind == .video {
                        Button {
                            let id = ProjectActions.newStory(asset: asset, env: env)
                            dismiss()
                            env.router.select(.stories)
                            env.router.push(.story(id))
                        } label: {
                            Label("قصة ذكية من هذا الفيديو", systemImage: "scissors")
                        }
                        .buttonStyle(.csPrimary)
                    }
                }
                .padding(Theme.Space.md)
            }
            .screenBackground()
            .navigationTitle(asset.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
            .onAppear {
                if asset.kind != .image {
                    player.frameRate = asset.frameRate ?? 30
                    player.load(url: env.library.url(for: asset))
                }
            }
            .onDisappear { player.pause() }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.Palette.textPrimary).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
