//
//  AssistantExtrasViews.swift
//  ClipStudio — Features/AI (Part 6 suggestions)
//
//  • PlanHistorySheet: every plan applied in this project — review the steps and
//    apply a plan again (steps whose clips no longer exist are reported).
//  • AssistantMemoryView: what the assistant learned from your edits, your own
//    notes about your style, and switches to pause or clear the memory.
//

import SwiftUI

struct PlanHistorySheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var records: [PlanRecord] = []
    @State private var expanded: Set<UUID> = []
    @State private var status: [UUID: String] = [:]
    @State private var confirmClear = false
    @State private var search = ""

    private var filtered: [PlanRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter { record in
            record.request.localizedCaseInsensitiveContains(query) || record.plan.steps.contains { $0.summary.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    EmptyStateView(systemImage: "clock.arrow.circlepath", title: "لا توجد خطط بعد",
                                   message: "كل خطة تطبّقها من مساعد المونتاج تُحفظ هنا لتراجعها أو تطبّقها مرة أخرى.")
                } else {
                    List {
                        ForEach(filtered) { record in
                            recordRow(record)
                        }
                        .onDelete { offsets in
                            for index in offsets { PlanHistoryStore.remove(filtered[index].id, projectID: vm.project.id) }
                            reload()
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .searchable(text: $search, prompt: "ابحث في الطلبات")
                }
            }
            .screenBackground()
            .navigationTitle("سجل الخطط")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button("مسح الكل", role: .destructive) { confirmClear = true }.disabled(records.isEmpty)
                }
            }
            .confirmationDialog("مسح سجل الخطط لهذا المشروع؟", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("مسح", role: .destructive) {
                    PlanHistoryStore.clear(vm.project.id)
                    reload()
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() { records = PlanHistoryStore.load(vm.project.id) }

    private func recordRow(_ record: PlanRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) }
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.request).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(Fmt.date(record.date) + " • " + Fmt.int(record.plan.steps.filter(\.isEnabled).count)
                             + " خطوة • " + record.provider.title)
                            .font(.caption2).foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Spacer()
                    Image(systemName: expanded.contains(record.id) ? "chevron.up" : "chevron.down").foregroundStyle(Theme.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.contains(record.id) {
                ForEach(Array(record.plan.steps.filter(\.isEnabled).enumerated()), id: \.element.id) { index, step in
                    Text(Fmt.int(index + 1) + ". " + step.summary).font(.callout)
                }
                if !record.result.isEmpty { Text(record.result).font(.caption).foregroundStyle(Theme.Palette.textSecondary) }
                HStack {
                    if let message = status[record.id] {
                        Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.Palette.success)
                    }
                    Spacer()
                    Button {
                        Task {
                            let summary = await vm.applyPlan(record.plan)
                            status[record.id] = summary
                        }
                    } label: { Label("طبّق مرة أخرى", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AssistantMemoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var memory = AssistantMemory.shared
    @State private var notes = ""
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("تعلّم من تعديلاتي", isOn: Binding(get: { memory.isEnabled }, set: { memory.isEnabled = $0 }))
                } footer: {
                    Text("الذاكرة على جهازك فقط. تُرسل خلاصة قصيرة منها مع طلبات المساعد ليختار ما تفضّله عندما لا تحدد.")
                }
                Section {
                    TextField("مثال: عناويني دائمًا في الأعلى وبخط عريض، وأحب الانتقالات السريعة", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: notes) { _, value in memory.notes = value }
                } header: {
                    Text("ملاحظات عن أسلوبك")
                }
                Section {
                    if memory.entries.isEmpty {
                        Text("لم يتعلّم شيئًا بعد — طبّق بعض الخطط من المساعد.").foregroundStyle(Theme.Palette.textSecondary)
                    } else {
                        ForEach(memory.entries) { entry in
                            HStack {
                                Text(entry.title)
                                Spacer()
                                Text(Fmt.int(entry.count) + "×").font(.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textTertiary)
                            }
                            .swipeActions {
                                Button("انسَ", role: .destructive) { memory.forget(entry.key) }
                            }
                        }
                    }
                } header: {
                    Text("ما تعلّمه")
                } footer: {
                    Text("يُستخدم ما تكرر مرتين أو أكثر. اسحب أي سطر لنسيانه.")
                }
                Section {
                    Button("مسح الذاكرة", role: .destructive) { confirmReset = true }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("ذاكرة المساعد")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
            .confirmationDialog("مسح كل ما تعلّمه المساعد وملاحظاتك؟", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("مسح", role: .destructive) {
                    memory.reset()
                    notes = ""
                }
            }
            .onAppear { notes = memory.notes }
        }
    }
}
