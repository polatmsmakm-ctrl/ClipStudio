//
//  AssistantSheet.swift
//  ClipStudio — Features/AI (Part 5)
//
//  AI Editing Assistant: ask for edits in your own words ("احذف الصمت وأضف عنوان
//  في البداية"). The answer streams in, and requested edits come back as a plan —
//  numbered steps you can switch off — that you apply (one undo step), or try
//  first with "معاينة" (keep / undo). Only a text description of the timeline
//  is sent (names, texts, times) — never media. Works offline with the on-device
//  command parser.
//  Part 6: voice commands (live dictation), plan history, and assistant memory
//  (applied plans teach it your preferences).
//

import SwiftUI

struct AssistantEntry: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    var plan: AIPlan?
    var provider: AIProviderKind?
    var note: String?
    var status: String?
    var isStreaming = false
    var previewing = false
    /// The user's request this answer belongs to (plan history).
    var request = ""
}

struct AssistantSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AssistantEntry] = []
    @State private var input = ""
    @State private var working = false
    @State private var useLocal = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool
    // Part 6
    @State private var dictation = LiveDictation()
    @AppStorage("assistant.voiceLocale") private var voiceLocale = "ar-SA"
    @AppStorage("assistant.autoSend") private var autoSend = true
    @State private var serverAllowed = false
    @State private var askServer = false
    @State private var dictationError: String?
    @State private var showHistory = false
    @State private var showMemory = false

    private let examples = [
        "احذف الصمت الأطول من ثانية",
        "أضف عنوان \"مرحبًا\" في البداية",
        "انتقال تلاشي بين كل المقاطع",
        "اجعل الألوان أدفأ قليلًا",
        "سرّع المقطع المحدد ×2",
        "قص المقاطع على الإيقاع"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            header
                            ForEach($entries) { $entry in
                                bubble($entry).id(entry.id)
                            }
                        }
                        .padding(Theme.Space.md)
                    }
                    .onChange(of: entries.count) { _, _ in
                        if let last = entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                inputBar
            }
            .screenBackground()
            .navigationTitle("مساعد المونتاج")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Toggle("على الجهاز فقط", isOn: $useLocal)
                        Button { showHistory = true } label: { Label("سجل الخطط", systemImage: "clock.arrow.circlepath") }
                        Button { showMemory = true } label: { Label("ذاكرة المساعد", systemImage: "brain") }
                        Section("الأوامر الصوتية") {
                            Picker("اللغة", selection: $voiceLocale) {
                                Text("العربية").tag("ar-SA")
                                Text("English").tag("en-US")
                            }
                            Toggle("إرسال تلقائي بعد الكلام", isOn: $autoSend)
                        }
                        Button("مسح المحادثة", role: .destructive) { entries = [] }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("خيارات المساعد")
                }
            }
            .onDisappear {
                task?.cancel()
                dictation.stop(deliver: false)
            }
            .onChange(of: dictation.text) { _, value in
                if dictation.isListening { input = value }
            }
            .sheet(isPresented: $showHistory) { PlanHistorySheet(vm: vm) }
            .sheet(isPresented: $showMemory) { AssistantMemoryView() }
            .confirmationDialog("الأوامر الصوتية بهذه اللغة غير متاحة على جهازك. إرسال الصوت إلى Apple للتعرّف عليه؟",
                                isPresented: $askServer, titleVisibility: .visible) {
                Button("اسمح لهذه الجلسة") {
                    serverAllowed = true
                    startDictation()
                }
                Button("إلغاء", role: .cancel) {}
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if useLocal {
                    StatusPill(text: "على الجهاز", systemImage: "iphone")
                } else {
                    AIProviderBadge(task: .assistant)
                }
                Spacer()
            }
            Text("اطلب التعديل بكلامك. تظهر الخطة قبل التنفيذ وتقدر تلغي أي خطوة. يُرسل وصف الخط الزمني فقط (أسماء ونصوص وأوقات) — لا تُرسل أي وسائط.")
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            if entries.isEmpty {
                FlowChips(items: examples) { example in
                    input = example
                    send()
                }
            }
        }
    }

    private func bubble(_ entry: Binding<AssistantEntry>) -> some View {
        let value = entry.wrappedValue
        let isUser = value.role == .user
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            if !value.text.isEmpty || value.isStreaming {
                HStack(alignment: .bottom) {
                    if isUser { Spacer(minLength: 40) }
                    Group {
                        if value.text.isEmpty && value.isStreaming {
                            TypingIndicator()
                        } else {
                            Text(value.text).textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isUser ? Theme.Palette.accentSoft : Theme.Palette.surfaceRaised.opacity(0.9)))
                    .contextMenu {
                        Button { UIPasteboard.general.string = value.text } label: { Label("نسخ", systemImage: "doc.on.doc") }
                    }
                    if !isUser { Spacer(minLength: 40) }
                }
            }
            if let note = value.note {
                Label(note, systemImage: "info.circle").font(.caption2).foregroundStyle(Theme.Palette.warning)
            }
            if let plan = value.plan, !plan.steps.isEmpty || !plan.warnings.isEmpty {
                planCard(entry)
            }
            if let status = value.status {
                Label(status, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.Palette.success)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func planCard(_ entry: Binding<AssistantEntry>) -> some View {
        let plan = entry.wrappedValue.plan ?? AIPlan(explanation: "", steps: [], warnings: [])
        let applied = entry.wrappedValue.status != nil
        let canPreview = plan.steps.filter(\.isEnabled).allSatisfy { !$0.operation.isDeferred }
        return GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Label("الخطة (" + Fmt.int(plan.steps.count) + " خطوة)", systemImage: "list.number").font(.subheadline.weight(.semibold))
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    Toggle(isOn: Binding(get: { entry.wrappedValue.plan?.steps[index].isEnabled ?? false },
                                         set: { entry.wrappedValue.plan?.steps[index].isEnabled = $0 })) {
                        HStack(spacing: 6) {
                            if step.isDestructive { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Palette.warning) }
                            Text(Fmt.int(index + 1) + ". " + step.summary).font(.callout)
                        }
                    }
                    .disabled(applied)
                }
                ForEach(plan.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Theme.Palette.warning)
                }
                if entry.wrappedValue.previewing {
                    HStack {
                        Text("تمت المعاينة على المشروع").font(.caption)
                        Spacer()
                        Button("تراجع") {
                            vm.performUndo()
                            entry.wrappedValue.previewing = false
                        }
                        .buttonStyle(.bordered)
                        Button("إبقاء") {
                            entry.wrappedValue.previewing = false
                            entry.wrappedValue.status = "تم التطبيق"
                            remember(entry.wrappedValue, plan: plan, result: "تم التطبيق بعد المعاينة")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if !applied, !plan.steps.isEmpty {
                    HStack {
                        if canPreview {
                            Button("معاينة") {
                                Task {
                                    _ = await vm.applyPlan(plan)
                                    entry.wrappedValue.previewing = true
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                        Button {
                            Task {
                                let summary = await vm.applyPlan(plan)
                                entry.wrappedValue.status = summary
                                remember(entry.wrappedValue, plan: plan, result: summary)
                            }
                        } label: { Label("طبّق", systemImage: "checkmark") }
                            .buttonStyle(.borderedProminent)
                            .disabled(!plan.steps.contains(where: \.isEnabled))
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let dictationError {
                Label(dictationError, systemImage: "mic.slash").font(.caption).foregroundStyle(Theme.Palette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if dictation.isListening {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(Theme.Palette.accent)
                    ProgressBarView(progress: dictation.level)
                    Text("أستمع…").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            inputRow
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Button { toggleDictation() } label: {
                Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(dictation.isListening ? Theme.Palette.danger : Theme.Palette.textSecondary)
            }
            .disabled(working)
            .accessibilityLabel(dictation.isListening ? "إيقاف الاستماع" : "أمر صوتي")
            TextField("اكتب طلبك…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.Palette.surfaceRaised))
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: working ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .disabled(!working && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(working ? "إيقاف" : "إرسال")
        }
    }

    // MARK: Voice commands & memory (Part 6)

    private func toggleDictation() {
        dictationError = nil
        if dictation.isListening {
            dictation.stop(deliver: true)
            return
        }
        if !LiveDictation.supportsOnDevice(voiceLocale) && !serverAllowed {
            askServer = true
            return
        }
        startDictation()
    }

    private func startDictation() {
        if vm.player.isPlaying { vm.player.pause() }
        focused = false
        let allowServer = serverAllowed
        Task {
            do {
                try await dictation.start(localeID: voiceLocale, allowServer: allowServer) { text in
                    input = text
                    if autoSend { send() }
                }
                Haptics.selection()
            } catch {
                dictationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func remember(_ entry: AssistantEntry, plan: AIPlan, result: String) {
        let record = PlanRecord(date: Date(), request: entry.request.isEmpty ? (plan.explanation.isEmpty ? "طلب" : plan.explanation) : entry.request,
                                plan: plan, provider: entry.provider ?? .local, result: result)
        PlanHistoryStore.add(record, projectID: vm.project.id)
        AssistantMemory.shared.learn(from: plan)
    }

    // MARK: Send

    private func history() -> [AIMessage] {
        entries.compactMap { entry -> AIMessage? in
            guard !entry.text.isEmpty else { return nil }
            return AIMessage(role: entry.role == .user ? .user : .model, parts: [.text(entry.text)])
        }
    }

    private func send() {
        if working {
            task?.cancel()
            working = false
            return
        }
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let previous = history()
        input = ""
        focused = false
        entries.append(AssistantEntry(role: .user, text: command))
        var reply = AssistantEntry(role: .assistant, text: "")
        reply.isStreaming = true
        reply.request = command
        entries.append(reply)
        let replyID = reply.id
        working = true
        let local = useLocal
        task = Task {
            do {
                let result = try await vm.askAssistant(command, history: previous, forceLocal: local) { delta in
                    if let index = entries.firstIndex(where: { $0.id == replyID }) { entries[index].text += delta }
                }
                if let index = entries.firstIndex(where: { $0.id == replyID }) {
                    entries[index].isStreaming = false
                    entries[index].provider = result.response.provider
                    entries[index].note = result.response.note
                    let explanation = result.plan.explanation
                    if entries[index].text.isEmpty {
                        entries[index].text = explanation.isEmpty
                            ? (result.plan.steps.isEmpty ? "لم أجد تعديلًا مناسبًا. وضّح طلبك أكثر." : "هذه الخطة المقترحة:")
                            : explanation
                    }
                    entries[index].plan = result.plan
                }
            } catch {
                if let index = entries.firstIndex(where: { $0.id == replyID }) {
                    entries[index].isStreaming = false
                    entries[index].text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            working = false
        }
    }
}

// MARK: - Small views

struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Theme.Palette.textSecondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * abs(sin(t * 3 + Double(index) * 0.8)))
                }
            }
        }
        .accessibilityLabel("يكتب…")
    }
}

/// Wrapping row of tappable suggestion chips.
struct FlowChips: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button { action(item) } label: {
                        Text(item)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Theme.Palette.surfaceRaised))
                            .overlay(Capsule().strokeBorder(Theme.Palette.stroke))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
