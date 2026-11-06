//
//  StoriesHubView.swift
//  ClipStudio — Features/Stories
//
//  Smart Stories home: split / merge / batch entry points and story projects.
//

import SwiftUI

struct StoriesHubView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showPicker = false
    @State private var search = ""

    private var stories: [ProjectSummary] {
        env.projects.summaries.filter { $0.kind == .story && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: sizeClass == .regular ? 3 : 1), spacing: 14) {
                    ToolTile(title: "تقسيم فيديو", subtitle: "مقاطع جاهزة لستوري وريلز وشورتس وواتساب", systemImage: "scissors") {
                        showPicker = true
                    }
                    ToolTile(title: "دمج فيديوهات", subtitle: "ترتيب وانتقالات وموسيقى وتوحيد المقاس", systemImage: "rectangle.stack.badge.plus") {
                        env.router.push(.mergeHome)
                    }
                    ToolTile(title: "معالجة دفعية", subtitle: "تقسيم وتحويل وضغط عدة ملفات بقائمة واحدة", systemImage: "square.stack.3d.down.right") {
                        env.router.push(.batch)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "مشاريع القصص", subtitle: Fmt.int(stories.count) + " مشروع", systemImage: "folder")
                    if stories.isEmpty {
                        EmptyStateView(systemImage: "scissors", title: "ابدأ أول قصة",
                                       message: "اختر فيديو طويل وسنقسمه لمقاطع بالحد المناسب لكل منصة — مع نقاط قطع ذكية عند تغيّر المشهد أو وقفات الكلام.",
                                       actionTitle: "اختيار فيديو") { showPicker = true }
                    } else {
                        ForEach(stories) { summary in
                            Button { env.router.push(.story(summary.id)) } label: {
                                ProjectRow(summary: summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $search, prompt: "بحث في القصص")
        .screenBackground()
        .navigationTitle("القصص الذكية")
        .sheet(isPresented: $showPicker) {
            MediaPickerSheet(title: "اختر فيديو للتقسيم", kinds: [.video], allowsMultiple: false) { assets in
                guard let asset = assets.first else { return }
                env.router.push(.story(ProjectActions.newStory(asset: asset, env: env)))
            }
        }
        .keyboardDoneToolbar()
    }
}

struct ProjectRow: View {
    @Environment(AppEnvironment.self) private var env
    let summary: ProjectSummary

    var body: some View {
        GlassCard(padding: 10) {
            HStack(spacing: 12) {
                Group {
                    if let id = summary.coverAssetID, let asset = env.library.asset(id) {
                        MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 1))
                    } else {
                        ZStack {
                            Theme.Palette.surfaceRaised
                            Image(systemName: summary.kind.symbol).foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                }
                .frame(width: 96, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        StatusPill(text: summary.kind.title, systemImage: summary.kind.symbol)
                        Text(Fmt.int(summary.itemCount) + (summary.kind == .story ? " مقطع" : " عنصر"))
                            .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Text(Fmt.duration(summary.durationSeconds) + " • " + Fmt.relative(summary.modifiedAt))
                        .font(.caption2).foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                let missing = summary.assetIDs.contains { id in env.library.asset(id).map { env.library.isMissing($0) } ?? true }
                if missing {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Palette.warning)
                        .accessibilityLabel("وسائط مفقودة")
                }
                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
    }
}
