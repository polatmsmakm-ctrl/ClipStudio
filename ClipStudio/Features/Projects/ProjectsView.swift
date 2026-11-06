//
//  ProjectsView.swift
//  ClipStudio — Features/Projects (ProjectManager UI)
//
//  All projects: search, filter, open, rename, duplicate, delete, version history.
//

import SwiftUI

struct ProjectsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var search = ""
    @State private var kindFilter: ProjectKind?
    @State private var renaming: ProjectSummary?
    @State private var renameText = ""
    @State private var deleting: ProjectSummary?

    private var visible: [ProjectSummary] {
        env.projects.summaries.filter { summary in
            (kindFilter == nil || summary.kind == kindFilter) &&
                (search.isEmpty || summary.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ChipButton(title: "الكل", isSelected: kindFilter == nil) { kindFilter = nil }
                        ForEach([ProjectKind.story, .merge], id: \.self) { kind in
                            ChipButton(title: kind.title, systemImage: kind.symbol, isSelected: kindFilter == kind) { kindFilter = kind }
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            if visible.isEmpty {
                EmptyStateView(systemImage: "folder", title: env.projects.summaries.isEmpty ? "لا توجد مشاريع" : "لا نتائج",
                               message: "المشاريع تُحفظ تلقائياً مع سجل إصدارات يمكنك الرجوع إليه في أي وقت.")
                    .listRowBackground(Color.clear)
            }

            ForEach(visible) { summary in
                Button { env.router.push(ProjectActions.route(for: summary)) } label: {
                    ProjectRow(summary: summary)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = summary } label: { Label("حذف", systemImage: "trash") }
                    Button {
                        if let copy = env.projects.duplicate(summary.id) { env.toasts.show("تم إنشاء نسخة: " + copy.name, style: .success) }
                    } label: { Label("نسخ", systemImage: "plus.square.on.square") }
                    .tint(Theme.Palette.accentDeep)
                }
                .contextMenu {
                    Button { env.router.push(ProjectActions.route(for: summary)) } label: { Label("فتح", systemImage: "arrow.up.forward.app") }
                    Button {
                        renameText = summary.name
                        renaming = summary
                    } label: { Label("إعادة تسمية", systemImage: "pencil") }
                    Button {
                        if let copy = env.projects.duplicate(summary.id) { env.toasts.show("تم إنشاء نسخة: " + copy.name, style: .success) }
                    } label: { Label("إنشاء نسخة", systemImage: "plus.square.on.square") }
                    Button { env.router.push(.versions(summary.id)) } label: { Label("سجل الإصدارات", systemImage: "clock.arrow.circlepath") }
                    Button(role: .destructive) { deleting = summary } label: { Label("حذف", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .padding(.horizontal, Theme.Space.md)
        .screenBackground()
        .navigationTitle("المشاريع")
        .searchable(text: $search, prompt: "بحث في المشاريع")
        .alert("إعادة تسمية", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") {
                if let target = renaming { env.projects.rename(target.id, to: renameText) }
                renaming = nil
            }
            Button("إلغاء", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("حذف المشروع نهائياً؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("حذف المشروع وسجل إصداراته", role: .destructive) {
                if let target = deleting { env.projects.delete(target.id) }
                deleting = nil
            }
        } message: {
            Text("الوسائط في المكتبة والملفات المصدّرة لا تُحذف.")
        }
        .keyboardDoneToolbar()
    }
}

struct VersionHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    let projectID: UUID
    @State private var versions: [ProjectVersion] = []
    @State private var restoring: ProjectVersion?
    @State private var current: ProjectSummary?

    var body: some View {
        List {
            if let current {
                Section("الإصدار الحالي") {
                    versionRow(current, date: current.modifiedAt, isCurrent: true)
                }
                .listRowBackground(Theme.Palette.surface.opacity(0.7))
            }
            Section {
                if versions.isEmpty {
                    Text("لا توجد إصدارات محفوظة بعد. تُحفظ نسخة تلقائياً كل بضع دقائق أثناء التعديل.")
                        .font(.footnote).foregroundStyle(Theme.Palette.textSecondary)
                }
                ForEach(versions) { version in
                    if let summary = version.summary {
                        VStack(alignment: .leading, spacing: 6) {
                            versionRow(summary, date: version.date, isCurrent: false)
                            if let current { Text(compare(summary, with: current)).font(.caption2).foregroundStyle(Theme.Palette.textTertiary) }
                        }
                        .swipeActions {
                            Button { restoring = version } label: { Label("استعادة", systemImage: "arrow.uturn.backward") }
                                .tint(Theme.Palette.accentDeep)
                        }
                        .contextMenu {
                            Button { restoring = version } label: { Label("استعادة هذا الإصدار", systemImage: "arrow.uturn.backward") }
                        }
                    }
                }
            } header: {
                Text("الإصدارات السابقة (" + Fmt.int(versions.count) + ")").textCase(nil)
            }
            .listRowBackground(Theme.Palette.surface.opacity(0.7))
        }
        .screenBackground()
        .navigationTitle("سجل الإصدارات")
        .onAppear(perform: reload)
        .confirmationDialog("استعادة هذا الإصدار؟", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible) {
            Button("استعادة") {
                if let version = restoring, env.projects.restore(version, into: projectID) != nil {
                    env.toasts.show("تمت الاستعادة — الحالة السابقة محفوظة كإصدار", style: .success)
                    reload()
                }
                restoring = nil
            }
        } message: {
            Text("تُحفظ الحالة الحالية أولاً كإصدار، فتقدر ترجع لها لاحقاً.")
        }
    }

    private func reload() {
        versions = env.projects.versions(for: projectID)
        current = env.projects.load(projectID).map { ProjectSummary(project: $0) }
    }

    private func versionRow(_ summary: ProjectSummary, date: Date, isCurrent: Bool) -> some View {
        HStack {
            Image(systemName: isCurrent ? "star.circle.fill" : "clock").foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.date(date)).font(.subheadline.weight(.semibold))
                Text(summary.name + " • " + Fmt.int(summary.itemCount) + " عنصر • " + Fmt.duration(summary.durationSeconds))
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private func compare(_ old: ProjectSummary, with current: ProjectSummary) -> String {
        var diffs: [String] = []
        if old.name != current.name { diffs.append("الاسم: " + old.name) }
        let itemDelta = current.itemCount - old.itemCount
        if itemDelta != 0 { diffs.append("العناصر: " + (itemDelta > 0 ? "+" : "") + Fmt.int(itemDelta) + " منذ ذلك الحين") }
        let durationDelta = current.durationSeconds - old.durationSeconds
        if abs(durationDelta) > 0.05 { diffs.append("المدة: " + (durationDelta > 0 ? "+" : "-") + Fmt.durationPrecise(abs(durationDelta))) }
        return diffs.isEmpty ? "مطابق للحالية تقريباً" : diffs.joined(separator: " • ")
    }
}
