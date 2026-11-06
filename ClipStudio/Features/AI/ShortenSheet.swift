//
//  ShortenSheet.swift
//  ClipStudio — Features/AI (Part 6 suggestions)
//
//  "Make it 30 seconds": from the transcribed speech, Gemini (sentence text and
//  times only) or the on-device scorer picks the sentences to keep. Review —
//  switch any sentence on or off and watch the resulting length — then cut
//  everything else from every track in one undo step.
//

import SwiftUI

struct ShortenSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var target: Double = 30
    @State private var sentences: [ShortenSentence] = []
    @State private var keep: Set<Int> = []
    @State private var working = false
    @State private var note: String?
    @State private var summary = ""
    @State private var useLocal = false
    @State private var loaded = false

    private var removals: [TimeSpan] {
        SmartShortener.removalSpans(keep: keep, sentences: sentences, totalDuration: vm.duration)
    }
    private var resulting: Double { SmartShortener.resultingDuration(totalDuration: vm.duration, removals: removals) }

    var body: some View {
        NavigationStack {
            Group {
                if loaded && sentences.isEmpty {
                    EmptyStateView(systemImage: "text.word.spacing", title: "لا يوجد كلام مفرّغ",
                                   message: "الاختصار الذكي يعتمد على كلام الفيديو. افتح «الكلام كنص» وفرّغ الكلام أولًا (على جهازك).",
                                   actionTitle: "الكلام كنص") { vm.activeSheet = .transcript }
                } else {
                    form
                }
            }
            .screenBackground()
            .navigationTitle("اختصار ذكي")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("اختصر") {
                        vm.applyShortening(keep: keep, sentences: sentences, target: target)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(keep.isEmpty || removals.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var form: some View {
        Form {
            Section {
                PrecisionSlider(title: "المدة المطلوبة", value: $target, range: 5...max(6, min(600, vm.duration - 1)), defaultValue: 30,
                                step: 1, format: { Fmt.seconds($0, digits: 0) })
                HStack(spacing: 8) {
                    ForEach([15.0, 30, 45, 60, 90], id: \.self) { value in
                        ChipButton(title: Fmt.int(Int(value)) + " ث", isSelected: target == value) { target = value }
                            .disabled(value >= vm.duration)
                    }
                }
                HStack {
                    if useLocal { StatusPill(text: "على الجهاز", systemImage: "iphone") } else { AIProviderBadge(task: .shorten) }
                    Spacer()
                    Toggle("على الجهاز", isOn: $useLocal).labelsHidden().fixedSize()
                }
                Button { choose() } label: {
                    HStack {
                        Label(keep.isEmpty ? "اختر الجمل الأهم" : "اختر من جديد", systemImage: "scissors")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(working || sentences.isEmpty)
                if let note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.Palette.warning) }
            } header: {
                Text("الآن " + Fmt.duration(vm.duration))
            } footer: {
                Text("يُرسل نص الجمل وأوقاتها فقط عند استخدام Gemini. لا يُحذف شيء قبل «اختصر»، والتراجع خطوة واحدة.")
            }
            if !keep.isEmpty {
                Section {
                    LabeledContent("المدة بعد الاختصار", value: Fmt.duration(resulting))
                        .foregroundStyle(resulting > target * 1.1 ? Theme.Palette.warning : Theme.Palette.success)
                    if !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(Theme.Palette.textSecondary) }
                }
            }
            if !sentences.isEmpty {
                Section {
                    ForEach(sentences) { sentence in
                        Button {
                            if keep.contains(sentence.index) { keep.remove(sentence.index) } else { keep.insert(sentence.index) }
                            Haptics.selection()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: keep.contains(sentence.index) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(keep.contains(sentence.index) ? Theme.Palette.accent : Theme.Palette.textTertiary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sentence.text)
                                        .foregroundStyle(keep.contains(sentence.index) || keep.isEmpty ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                                    Text(Fmt.durationPrecise(sentence.start) + " • " + Fmt.seconds(sentence.duration, digits: 1))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.Palette.textTertiary)
                                }
                                Spacer()
                                Button { vm.seek(to: sentence.start) } label: { Image(systemName: "play.circle") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("انتقل إلى الجملة")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(keep.contains(sentence.index) ? .isSelected : [])
                    }
                } header: {
                    Text("الجمل (" + Fmt.int(sentences.count) + ")")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func load() {
        guard !loaded else { return }
        let input = vm.shortenInput(target: target)
        sentences = input.sentences
        target = min(30, max(5, (vm.duration * 0.5).rounded()))
        loaded = true
    }

    private func choose() {
        working = true
        note = nil
        let input = ShortenInput(sentences: sentences, target: target, totalDuration: vm.duration)
        let local = useLocal
        Task {
            do {
                let result = try await SmartShortener.choose(input, forceLocal: local)
                keep = result.keep
                summary = result.summary
                note = result.response.note
                Haptics.success()
            } catch {
                keep = SmartShortener.select(sentences, target: target)
                summary = "اختيار على الجهاز."
                note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }
}
