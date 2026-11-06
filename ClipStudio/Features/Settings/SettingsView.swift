//
//  SettingsView.swift
//  ClipStudio — Features/Settings
//
//  Defaults, platforms, Pro Studio preferences & LUT library, storage, backup &
//  restore, interface, widget status, about. Part 4: templates, editing styles
//  and the optional Core ML separation model. Part 5: the AI section (Gemini key,
//  model, privacy, usage) and the AI studio.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section("التصدير") {
                NavigationLink(value: Route.exportDefaults) {
                    Label("الإعدادات الافتراضية للتصدير", systemImage: "square.and.arrow.up")
                }
                NavigationLink(value: Route.platformPresets) {
                    Label("منصات التواصل", systemImage: "apps.iphone")
                }
            }
            Section("الاستوديو الاحترافي") {
                NavigationLink(value: Route.studioPreferences) {
                    Label("تفضيلات الخط الزمني والقلم", systemImage: "film.stack")
                }
                NavigationLink(value: Route.lutLibrary) {
                    Label("جداول الألوان LUT", systemImage: "cube")
                }
                NavigationLink(value: Route.templates) {
                    Label("القوالب", systemImage: "square.grid.3x3.square")
                }
                NavigationLink(value: Route.editingStyles) {
                    Label("أساليب المونتاج", systemImage: "dna")
                }
            }
            Section {
                NavigationLink(value: Route.aiSettings) {
                    HStack {
                        Label("Gemini — المفتاح والنموذج", systemImage: "sparkles")
                        Spacer()
                        Text(AISettings.shared.keySource.title).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                NavigationLink(value: Route.aiStudio) {
                    Label("استوديو الذكاء", systemImage: "wand.and.stars")
                }
                NavigationLink(value: Route.performance) {
                    Label("الأداء والنسخ الخفيفة وتسهيلات الاستخدام", systemImage: "gauge.with.dots.needle.67percent")
                }
            } header: {
                Text("الذكاء الاصطناعي")
            } footer: {
                Text("بمفتاحك المجاني من Google AI Studio. بدون مفتاح تعمل الأدوات على جهازك بنتائج أبسط.")
            }
            Section {
                NavigationLink(value: Route.onDeviceAI) {
                    Label("نموذج فصل الصوت (Core ML)", systemImage: "cpu")
                }
            } header: {
                Text("الذكاء على الجهاز")
            } footer: {
                Text("التتبع والتثبيت والإيقاع وفحص الجودة تعمل على جهازك بدون إنترنت.")
            }
            Section("البيانات") {
                NavigationLink(value: Route.storage) {
                    Label("التخزين", systemImage: "internaldrive")
                }
                NavigationLink(value: Route.backup) {
                    Label("النسخ الاحتياطي والاستعادة", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                }
                NavigationLink(value: Route.projects) {
                    Label("المشاريع وسجل الإصدارات", systemImage: "folder")
                }
            }
            Section("الواجهة والأداء") {
                Toggle(isOn: $settings.hapticsEnabled) { Label("الاهتزاز اللمسي", systemImage: "hand.tap") }
                Toggle(isOn: $settings.animatedBackground) { Label("خلفية متحركة", systemImage: "sparkles") }
                Picker(selection: $settings.previewQuality) {
                    ForEach(AppSettings.PreviewQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Label("جودة المعاينة", systemImage: "eye") }
            }
            Section {
                HStack {
                    Label("ودجت الشاشة الرئيسية والقفل", systemImage: "square.text.square")
                    Spacer()
                    StatusPill(text: AppGroup.isAvailable ? "مفعّل" : "غير متاح",
                               color: AppGroup.isAvailable ? Theme.Palette.success : Theme.Palette.textTertiary)
                }
                if !AppGroup.isAvailable {
                    Text("الودجت يحتاج App Group. عند التوقيع عبر Sideloadly فعّل خيار App Group أو أضِف group.com.rashid.clipstudio لمعرّف التطبيق في حساب المطوّر. التطبيق يعمل بالكامل بدونه.")
                        .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            } header: { Text("الودجت") }
            Section("حول") {
                HStack {
                    Text("الإصدار")
                    Spacer()
                    Text((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") + " ("
                         + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") + ")")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Label("كل المعالجة تتم على جهازك. لا توجد حسابات ولا سيرفرات.", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .screenBackground()
        .navigationTitle("الإعدادات")
        .onAppear {
            if env.router.pendingBackupURL != nil { env.router.push(.backup) }
        }
    }
}

struct StorageView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sizes: [String: Int64] = [:]
    @State private var confirmClearCache = false
    @State private var confirmDeleteUnused = false

    private var unused: [MediaAsset] { env.library.unusedAssets(projects: env.projects) }

    var body: some View {
        List {
            Section("المساحة") {
                row("الوسائط المستوردة", sizes["media"], "film")
                row("الملفات المصدّرة", sizes["exports"], "square.and.arrow.up")
                row("المشاريع والإصدارات", sizes["projects"], "folder")
                row("النسخ الاحتياطية", sizes["backups"], "externaldrive")
                row("الذاكرة المؤقتة", sizes["cache"], "clock.arrow.circlepath")
                HStack {
                    Label("المساحة المتاحة في الجهاز", systemImage: "internaldrive")
                    Spacer()
                    Text(Fmt.bytes(StorageManager.shared.freeSpace)).foregroundStyle(Theme.Palette.success)
                }
            }
            .listRowBackground(Theme.Palette.surface.opacity(0.7))
            Section {
                Button { confirmClearCache = true } label: { Label("مسح الذاكرة المؤقتة (المصغّرات والتحليل)", systemImage: "trash") }
                Button(role: .destructive) { confirmDeleteUnused = true } label: {
                    Label("حذف الوسائط غير المستخدمة (" + Fmt.int(unused.count) + ")", systemImage: "film.stack")
                }
                .disabled(unused.isEmpty)
                Button {
                    FilesAppLink.openFolder(StorageManager.shared.exportsDirectory)
                } label: { Label("فتح مجلد الصادرات في الملفات", systemImage: "folder") }
            } header: {
                Text("تنظيف")
            } footer: {
                Text("حذف الوسائط يحذف النسخة داخل التطبيق فقط؛ الأصل في الصور أو الملفات لا يتأثر.")
            }
            .listRowBackground(Theme.Palette.surface.opacity(0.7))
        }
        .screenBackground()
        .navigationTitle("التخزين")
        .task { await refresh() }
        .confirmationDialog("مسح الذاكرة المؤقتة؟", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("مسح") {
                StorageManager.shared.clearCaches()
                ThumbnailService.shared.clearMemory()
                Task { await refresh() }
            }
        }
        .confirmationDialog("حذف " + Fmt.int(unused.count) + " ملف غير مستخدم في أي مشروع؟", isPresented: $confirmDeleteUnused, titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                for asset in unused { env.library.delete(asset.id) }
                Task { await refresh() }
            }
        }
    }

    private func row(_ title: String, _ value: Int64?, _ symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let value { Text(Fmt.bytes(value)).foregroundStyle(Theme.Palette.textSecondary) } else { ProgressView() }
        }
    }

    private func refresh() async {
        let storage = StorageManager.shared
        let result = await Task.detached(priority: .utility) { () -> [String: Int64] in
            [
                "media": storage.directorySize(storage.mediaDirectory),
                "exports": storage.directorySize(storage.exportsDirectory),
                "projects": storage.directorySize(storage.projectsDirectory),
                "backups": storage.directorySize(storage.backupsDirectory),
                "cache": storage.directorySize(storage.cachesDirectory)
            ]
        }.value
        sizes = result
    }
}

struct BackupView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var includeMedia = true
    @State private var includeExports = false
    @State private var shareItem: ShareItem?
    @State private var showImporter = false
    @State private var pendingRestore: URL?
    @State private var lastSummary: String?

    var body: some View {
        Form {
            Section {
                Toggle("تضمين الوسائط المستوردة", isOn: $includeMedia)
                Toggle("تضمين الفيديوهات المصدّرة", isOn: $includeExports)
                Text("الحجم التقريبي: " + Fmt.bytes(estimate)).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                Button {
                    Task {
                        do {
                            let url = try await env.backup.createBackup(includeMedia: includeMedia, includeExports: includeExports)
                            shareItem = ShareItem(urls: [url])
                            env.toasts.show("تم إنشاء النسخة الاحتياطية", style: .success)
                        } catch {
                            env.toasts.show(error.localizedDescription, style: .error)
                        }
                    }
                } label: { Label("إنشاء نسخة احتياطية", systemImage: "arrow.up.doc") }
                .disabled(env.backup.isWorking)
            } header: {
                Text("تصدير")
            } footer: {
                Text("يُحفظ الملف (.csbackup) في تطبيق الملفات › ClipStudio › Backups ويمكنك مشاركته أو حفظه في iCloud.")
            }
            Section {
                Button { showImporter = true } label: { Label("استعادة من ملف", systemImage: "arrow.down.doc") }
                    .disabled(env.backup.isWorking)
                if let lastSummary {
                    Text(lastSummary).font(.caption).foregroundStyle(Theme.Palette.success)
                }
            } header: {
                Text("استيراد")
            } footer: {
                Text("الاستعادة تدمج البيانات ولا تحذف أي شيء من جهازك. المشروع يُستبدل فقط إذا كانت نسخته في الملف أحدث.")
            }
            if env.backup.isWorking {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(env.backup.statusText).font(.subheadline)
                        ProgressBarView(progress: env.backup.progress)
                        Button("إلغاء", role: .destructive) { env.backup.cancel() }
                    }
                }
            }
        }
        .screenBackground()
        .navigationTitle("النسخ الاحتياطي")
        .sheet(item: $shareItem) { ShareSheet(items: $0.urls) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [BackupView.backupType, .data]) { result in
            if case .success(let url) = result { pendingRestore = url }
        }
        .confirmationDialog("استعادة النسخة الاحتياطية؟", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("استعادة ودمج") {
                guard let url = pendingRestore else { return }
                pendingRestore = nil
                Task {
                    do {
                        let summary = try await env.backup.restore(from: url, library: env.library)
                        lastSummary = summary.text
                        env.toasts.show("اكتملت الاستعادة", style: .success)
                    } catch {
                        env.toasts.show(error.localizedDescription, style: .error)
                    }
                }
            }
        }
        .onAppear {
            if let url = env.router.pendingBackupURL {
                pendingRestore = url
                env.router.pendingBackupURL = nil
            }
        }
    }

    private var estimate: Int64 {
        let storage = StorageManager.shared
        var total = env.library.totalBytes * (includeMedia ? 1 : 0)
        if includeExports { total += env.history.totalBytes }
        total += storage.directorySize(storage.projectsDirectory)
        return total
    }

    static let backupType = UTType(exportedAs: "com.rashid.clipstudio.backup")
}
