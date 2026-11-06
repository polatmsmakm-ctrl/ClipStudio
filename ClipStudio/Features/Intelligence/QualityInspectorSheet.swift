//
//  QualityInspectorSheet.swift
//  ClipStudio — Features/Intelligence (Part 4)
//
//  Pre-export check: instant checks on open, optional deep scan (real loudness
//  and exposure measurements), grouped by category with jump-to and one-tap fixes.
//

import SwiftUI

struct QualityInspectorSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var fast: [QualityIssue] = []
    @State private var deep: [QualityIssue] = []
    @State private var didDeepScan = false
    @State private var filter: QualitySeverity?

    private var all: [QualityIssue] {
        QualityInspector.sorted(fast + deep).filter { filter == nil || $0.severity == filter }
    }

    private var grouped: [QualityGroup] {
        QualityCategory.allCases.compactMap { category -> QualityGroup? in
            let items = all.filter { $0.category == category }
            return items.isEmpty ? nil : QualityGroup(category: category, issues: items)
        }
    }

    private func count(_ severity: QualitySeverity) -> Int {
        (fast + deep).filter { $0.severity == severity }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summary
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                if grouped.isEmpty {
                    Section {
                        EmptyStateView(systemImage: "checkmark.seal", title: filter == nil ? "جاهز للتصدير" : "لا يوجد",
                                       message: filter == nil
                                           ? (didDeepScan ? "لم يُعثر على مشاكل في الملفات أو الصورة أو الصوت."
                                                          : "الفحص السريع نظيف. جرّب الفحص العميق لقياس الصوت والإضاءة.")
                                           : "لا توجد عناصر بهذا المستوى.",
                                       actionTitle: filter == nil ? "تصدير" : nil) {
                            vm.activeSheet = .export
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(grouped) { group in
                        Section {
                            ForEach(group.issues) { issue in
                                QualityIssueRow(issue: issue,
                                                onJump: { vm.jump(to: issue) },
                                                onFix: { fix(issue) })
                            }
                        } header: {
                            Label(group.category.title, systemImage: group.category.symbol)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .studioBusyOverlay(vm)
            .navigationTitle("فحص الجودة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { refresh() } label: { Label("إعادة الفحص", systemImage: "arrow.clockwise") }
                }
            }
            .onAppear(perform: refresh)
        }
    }

    private var summary: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    severityChip(.problem, color: Theme.Palette.danger)
                    severityChip(.warning, color: Theme.Palette.warning)
                    severityChip(.info, color: Theme.Palette.textSecondary)
                }
                HStack {
                    Button {
                        vm.deepQualityScan { issues in
                            deep = issues
                            didDeepScan = true
                        }
                    } label: {
                        Label(didDeepScan ? "إعادة الفحص العميق" : "فحص عميق (الصوت والإضاءة)", systemImage: "waveform.and.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.busy != nil || vm.timeline.isEmpty)
                    Spacer()
                    Button { vm.activeSheet = .export } label: { Label("تصدير", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .disabled(count(.problem) > 0 && vm.timeline.isEmpty)
                }
            }
        }
    }

    private func severityChip(_ severity: QualitySeverity, color: Color) -> some View {
        Button {
            filter = filter == severity ? nil : severity
            Haptics.selection()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: severity.symbol)
                Text(severity.title + " " + Fmt.int(count(severity)))
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(filter == severity ? 0.3 : 0.12)))
        }
        .buttonStyle(.plain)
    }

    private func refresh() {
        fast = vm.runQualityCheck()
    }

    private func fix(_ issue: QualityIssue) {
        let resolved = vm.applyQualityFix(issue)
        if resolved {
            deep.removeAll { $0.id == issue.id }
            refresh()
        }
    }
}

struct QualityGroup: Identifiable {
    let category: QualityCategory
    let issues: [QualityIssue]
    var id: String { category.rawValue }
}

struct QualityIssueRow: View {
    let issue: QualityIssue
    let onJump: () -> Void
    let onFix: () -> Void

    private var color: Color {
        switch issue.severity {
        case .problem: Theme.Palette.danger
        case .warning: Theme.Palette.warning
        case .info: Theme.Palette.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.severity.symbol)
                    .foregroundStyle(color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title).font(.subheadline.weight(.semibold))
                    Text(issue.detail).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    if let time = issue.time {
                        Text(Fmt.durationPrecise(time)).font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if issue.time != nil || issue.clipID != nil {
                    Button { onJump() } label: { Label("انتقال", systemImage: "arrow.right.circle") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let fix = issue.fix {
                    Button { onFix() } label: { Label(fix.title, systemImage: "wand.and.stars") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
