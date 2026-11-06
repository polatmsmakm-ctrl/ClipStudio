//
//  ContentView.swift
//  ClipStudio — App
//
//  Adaptive root: NavigationSplitView with a sidebar on iPad (regular width),
//  TabView on iPhone. Every section has its own navigation stack. The Pro Studio
//  editor is presented full screen above everything. Part 4 adds the templates,
//  editing-styles and on-device AI destinations; Part 5 the AI studio and AI
//  settings.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var router = env.router
        Group {
            if sizeClass == .regular {
                splitLayout
            } else {
                tabLayout
            }
        }
        .onChange(of: sizeClass) { _, newClass in
            // Keep a valid tab when switching from iPad split view to compact width.
            if newClass == .compact, !AppSection.compactTabs.contains(env.router.section) {
                env.router.section = .dashboard
            }
        }
        .fullScreenCover(item: $router.studio) { presentation in
            StudioView(projectID: presentation.id)
                .environment(env)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Fmt.arabicLatin)
                .tint(Theme.Palette.accent)
        }
    }

    private var splitLayout: some View {
        @Bindable var router = env.router
        return NavigationSplitView {
            List(selection: Binding<AppSection?>(get: { router.section }, set: { if let s = $0 { router.section = s } })) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.Palette.accent)
                        Text("ClipStudio").font(.headline).foregroundStyle(Theme.Palette.textPrimary)
                    }
                    .textCase(nil)
                    .padding(.bottom, 6)
                }
                if let job = env.exportQueue.activeJob {
                    Section("التصدير الحالي") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.title).font(.caption).lineLimit(1)
                            ProgressBarView(progress: job.progress)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.surface.ignoresSafeArea())
        } detail: {
            SectionStack(section: router.section)
                .id(router.section)
        }
    }

    private var tabLayout: some View {
        @Bindable var router = env.router
        return TabView(selection: $router.section) {
            ForEach(AppSection.compactTabs) { section in
                SectionStack(section: section)
                    .tabItem { Label(section.title, systemImage: section.symbol) }
                    .tag(section)
                    .badge(section == .exports ? env.exportQueue.unfinishedCount : 0)
            }
        }
    }
}

/// A NavigationStack hosting a section root and all pushable routes.
struct SectionStack: View {
    @Environment(AppEnvironment.self) private var env
    let section: AppSection

    var body: some View {
        NavigationStack(path: env.router.path(for: section)) {
            root
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route)
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        switch section {
        case .dashboard: DashboardView()
        case .studio: StudioHubView()
        case .stories: StoriesHubView()
        case .merge: MergeHubView()
        case .batch: BatchView()
        case .media: MediaBrowserView()
        case .projects: ProjectsView()
        case .exports: ExportCenterView()
        case .settings: SettingsView()
        }
    }
}

struct RouteDestination: View {
    @Environment(AppEnvironment.self) private var env
    let route: Route

    var body: some View {
        switch route {
        case .story(let id): SplitterView(projectID: id)
        case .storyGallery(let id): StoryGalleryView(projectID: id)
        case .merge(let id): MergerView(projectID: id)
        case .mergeHome: MergeHubView()
        case .batch: BatchView()
        case .projects: ProjectsView()
        case .versions(let id): VersionHistoryView(projectID: id)
        case .exports: ExportCenterView()
        case .platformPresets: PlatformPresetsView()
        case .presetEditor(let id): PresetEditorView(presetID: id)
        case .storage: StorageView()
        case .backup: BackupView()
        case .exportDefaults: ExportDefaultsView()
        case .studio(let id): StudioLaunchView(projectID: id)
        case .studioHub: StudioHubView()
        case .mediaLibrary: MediaBrowserView()
        case .lutLibrary: LUTLibraryView()
        case .studioPreferences: StudioPreferencesView(prefs: env.studioPrefs)
        case .templates: TemplatesWorkspaceView()
        case .editingStyles: EditingStylesView()
        case .onDeviceAI: VoiceSeparationModelView()
        case .aiStudio: AIStudioView()
        case .aiSettings: AISettingsView()
        case .performance: PerformanceSettingsView()
        case .series: SeriesBuilderView()
        }
    }
}

/// Reached only through NavigationLink(value: .studio): opens the full-screen editor.
struct StudioLaunchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID

    var body: some View {
        ProgressView()
            .tint(Theme.Palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenBackground()
            .onAppear {
                dismiss()
                env.router.openStudio(projectID)
            }
    }
}
