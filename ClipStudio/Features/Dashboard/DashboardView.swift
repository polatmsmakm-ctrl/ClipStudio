//
//  DashboardView.swift
//  ClipStudio — Features/Dashboard
//
//  Main dashboard: quick actions for every workspace, current export,
//  crash-recovery banner, recent projects and library stats. Part 4: Templates,
//  Editing styles and beat auto-edit tiles. Part 5: AI studio tile.
//

import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pickerMode: PickerMode?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showNewStudio = false
    @State private var showAutoEdit = false

    enum PickerMode: String, Identifiable {
        case story, merge
        var id: String { rawValue }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: sizeClass == .regular ? 3 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header
                recoveryBanner
                ImportProgressCard(importer: env.importer)
                activeExportCard

                LazyVGrid(columns: columns, spacing: 14) {
                    ToolTile(title: "الاستوديو الاحترافي", subtitle: "مونتاج متعدد المسارات مع ألوان وإطارات مفتاحية", systemImage: "film.stack") {
                        showNewStudio = true
                    }
                    ToolTile(title: "قصة ذكية", subtitle: "قسّم فيديو طويل لمقاطع جاهزة للمنصات", systemImage: "scissors") {
                        pickerMode = .story
                    }
                    ToolTile(title: "دمج ذكي", subtitle: "ادمج مقاطع مع انتقالات وموسيقى", systemImage: "rectangle.stack.badge.plus") {
                        pickerMode = .merge
                    }
                    ToolTile(title: "معالجة دفعية", subtitle: "قسّم أو حوّل أو اضغط عدة ملفات مرة وحدة", systemImage: "square.stack.3d.down.right") {
                        env.router.select(.batch)
                    }
                    ToolTile(title: "مكتبة الوسائط", subtitle: Fmt.int(env.library.assets.count) + " ملف", systemImage: "photo.on.rectangle.angled") {
                        env.router.select(.media)
                    }
                    ToolTile(title: "مركز التصدير", subtitle: exportSubtitle, systemImage: "square.and.arrow.up.on.square",
                             badge: env.exportQueue.unfinishedCount > 0 ? Fmt.int(env.exportQueue.unfinishedCount) : nil) {
                        env.router.select(.exports)
                    }
                    ToolTile(title: "المشاريع", subtitle: Fmt.int(env.projects.summaries.count) + " مشروع", systemImage: "folder") {
                        env.router.select(.projects)
                    }
                    ToolTile(title: "جداول الألوان LUT", subtitle: Fmt.int(env.lutLibrary.luts.count) + " LUT", systemImage: "cube") {
                        env.router.push(.lutLibrary)
                    }
                    ToolTile(title: "القوالب", subtitle: Fmt.int(StudioTemplateLibrary.shared.templates.count) + " قالب بخانات للوسائط",
                             systemImage: "square.grid.3x3.square") {
                        env.router.push(.templates)
                    }
                    ToolTile(title: "أساليب المونتاج", subtitle: "تعلّم أسلوب أي فيديو وطبّقه على مشاريعك", systemImage: "dna") {
                        env.router.push(.editingStyles)
                    }
                    ToolTile(title: "مونتاج تلقائي على الإيقاع", subtitle: "اختر لقطات وأغنية وأسلوب", systemImage: "metronome") {
                        showAutoEdit = true
                    }
                    ToolTile(title: "استوديو الذكاء", subtitle: "قصة مصورة • أفضل اللقطات • محتوى النشر", systemImage: "sparkles") {
                        env.router.push(.aiStudio)
                    }
                    ToolTile(title: "سلسلة حلقات", subtitle: "عدة فيديوهات بنفس الأسلوب والمقدمة", systemImage: "square.stack.3d.down.right") {
                        env.router.push(.series)
                    }
                }

                recentProjects
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("الرئيسية")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ImportMenu(showPhotos: $showPhotos, showFiles: $showFiles) }
        }
        .mediaImport(showPhotos: $showPhotos, showFiles: $showFiles)
        .sheet(isPresented: $showNewStudio) {
            NewStudioProjectSheet { id in env.router.openStudio(id) }
        }
        .sheet(isPresented: $showAutoEdit) {
            BeatAutoEditSheet()
        }
        .sheet(item: $pickerMode) { mode in
            switch mode {
            case .story:
                MediaPickerSheet(title: "اختر فيديو للتقسيم", kinds: [.video], allowsMultiple: false) { assets in
                    guard let asset = assets.first else { return }
                    let id = ProjectActions.newStory(asset: asset, env: env)
                    env.router.push(.story(id))
                }
            case .merge:
                MediaPickerSheet(title: "اختر المقاطع بالترتيب", kinds: [.video, .image], allowsMultiple: true,
                                 confirmTitle: "دمج") { assets in
                    let id = ProjectActions.newMerge(assets: assets, env: env)
                    env.router.push(.merge(id))
                }
            }
        }
    }

    private var exportSubtitle: String {
        if let job = env.exportQueue.activeJob { return "جارٍ: " + Fmt.percent(job.progress) }
        return Fmt.int(env.history.completedToday) + " تصدير اليوم"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.Palette.accentSoft))
            VStack(alignment: .leading, spacing: 4) {
                Text("ClipStudio").font(Theme.Typo.hero).foregroundStyle(Theme.Palette.textPrimary)
                Text("استوديو مونتاج احترافي — كل المعالجة على جهازك")
                    .font(.subheadline).foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            StatusPill(text: "متاح " + Fmt.bytes(StorageManager.shared.freeSpace), color: Theme.Palette.textSecondary, systemImage: "internaldrive")
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var recoveryBanner: some View {
        if let id = env.projects.recoveredProjectID, let summary = env.projects.summary(id) {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.uturn.backward.circle.fill").font(.title2).foregroundStyle(Theme.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("تم استرجاع جلستك السابقة").font(.headline)
                        Text("آخر حفظ تلقائي لـ «" + summary.name + "» محفوظ بالكامل.").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    Button("فتح") {
                        env.projects.clearRecovery()
                        env.router.push(ProjectActions.route(for: summary))
                    }
                    .buttonStyle(.borderedProminent)
                    Button { env.projects.clearRecovery() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("إخفاء")
                }
            }
        }
    }

    @ViewBuilder
    private var activeExportCard: some View {
        if let job = env.exportQueue.activeJob {
            Button { env.router.select(.exports) } label: {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: job.status == .paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                                .foregroundStyle(Theme.Palette.accent)
                            Text(job.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text(Fmt.percent(job.progress)).font(Theme.Typo.mono)
                        }
                        ProgressBarView(progress: job.progress)
                        if env.exportQueue.pendingCount > 0 {
                            Text("في الانتظار: " + Fmt.int(env.exportQueue.pendingCount))
                                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    @ViewBuilder
    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "المشاريع الأخيرة", systemImage: "clock")
                if !env.projects.summaries.isEmpty {
                    Button("عرض الكل") { env.router.select(.projects) }.font(.subheadline)
                }
            }
            if env.projects.summaries.isEmpty {
                GlassCard {
                    Text("لا توجد مشاريع بعد. ابدأ بمشروع في الاستوديو أو قصة ذكية أو دمج.")
                        .font(.subheadline).foregroundStyle(Theme.Palette.textSecondary)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(env.projects.summaries.prefix(12)) { summary in
                            Button { env.router.push(ProjectActions.route(for: summary)) } label: {
                                ProjectCard(summary: summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct ProjectCard: View {
    @Environment(AppEnvironment.self) private var env
    let summary: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let id = summary.coverAssetID, let asset = env.library.asset(id) {
                    MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 1))
                } else {
                    ZStack {
                        Theme.Palette.surfaceRaised
                        Image(systemName: summary.kind.symbol).font(.title).foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
            }
            .frame(width: 200, height: 118)
            .overlay(alignment: .topLeading) {
                StatusPill(text: summary.kind.title, systemImage: summary.kind.symbol).padding(6)
            }
            Text(summary.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(Fmt.duration(summary.durationSeconds) + " • " + Fmt.relative(summary.modifiedAt))
                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(width: 200)
        .foregroundStyle(Theme.Palette.textPrimary)
    }
}
