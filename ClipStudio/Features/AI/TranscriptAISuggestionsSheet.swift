//
//  TranscriptAISuggestionsSheet.swift
//  ClipStudio — Features/AI (Part 5)
//
//  AI help for text-based editing: suggests words to cut (fillers, repetitions,
//  stumbles, off-topic parts) and long pauses. Nothing is deleted here — chosen
//  suggestions are only marked in the transcript editor, where the normal
//  "delete marked" action (one undo step, all tracks in sync) applies them.
//

import SwiftUI

struct TranscriptAISuggestionsSheet: View {
    @Bindable var vm: StudioViewModel
    let words: [TimelineWord]
    let onMark: (_ words: Set<Int>, _ pauses: Set<Int>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [TranscriptSuggestion] = []
    @State private var chosen: Set<UUID> = []
    @State private var working = false
    @State private var provider: AIProviderKind?
    @State private var note: String?
    @State private var useLocal = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        if useLocal { StatusPill(text: "على الجهاز", systemImage: "iphone") } else { AIProviderBadge(task: .transcriptCleanup) }
                        Spacer()
                        Toggle("على الجهاز", isOn: $useLocal).labelsHidden().fixedSize()
                    }
                    Text("يُرسل نص الكلام فقط (بدون صوت أو صورة) عند استخدام Gemini. لا يُحذف شيء قبل أن تؤكد في محرر النص.")
                        .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    Button { run() } label: {
                        HStack {
                            Label(suggestions.isEmpty ? "اقترح ما يُحذف" : "اقترح من جديد", systemImage: "sparkles")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || words.isEmpty)
                    if let note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.Palette.warning) }
                }
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { suggestion in
                            Button {
                                if chosen.contains(suggestion.id) { chosen.remove(suggestion.id) } else { chosen.insert(suggestion.id) }
                                Haptics.selection()
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: chosen.contains(suggestion.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(suggestion.id) ? Theme.Palette.danger : Theme.Palette.textTertiary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(phrase(suggestion)).strikethrough(chosen.contains(suggestion.id), color: Theme.Palette.danger)
                                        HStack(spacing: 6) {
                                            StatusPill(text: suggestion.kind.title, color: Theme.Palette.textSecondary)
                                            if !suggestion.reason.isEmpty {
                                                Text(suggestion.reason).font(.caption2).foregroundStyle(Theme.Palette.textTertiary).lineLimit(2)
                                            }
                                        }
                                    }
                                    Spacer()
                                    Button { vm.seek(to: words[suggestion.startWord].start) } label: { Image(systemName: "play.circle") }
                                        .buttonStyle(.plain)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("الاقتراحات (" + Fmt.int(suggestions.count) + ")")
                            Spacer()
                            Button(chosen.count == suggestions.count ? "إلغاء الكل" : "تحديد الكل") {
                                chosen = chosen.count == suggestions.count ? [] : Set(suggestions.map(\.id))
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("اقتراحات الذكاء")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حدّد في النص") { mark() }.fontWeight(.semibold).disabled(chosen.isEmpty)
                }
            }
        }
    }

    private func phrase(_ suggestion: TranscriptSuggestion) -> String {
        if suggestion.kind == .pause {
            let gap = suggestion.startWord + 1 < words.count ? words[suggestion.startWord + 1].start - words[suggestion.startWord].end : 0
            return "وقفة " + Fmt.seconds(max(0, gap), digits: 1) + " بعد «" + words[suggestion.startWord].text + "»"
        }
        return words[suggestion.startWord...suggestion.endWord].map(\.text).joined(separator: " ")
    }

    private func run() {
        working = true
        note = nil
        let local = useLocal
        Task {
            do {
                let result = try await vm.transcriptSuggestions(words: words, forceLocal: local)
                suggestions = result.suggestions
                chosen = Set(result.suggestions.filter { $0.kind != .offTopic }.map(\.id))
                provider = result.response.provider
                note = result.response.note
                if result.suggestions.isEmpty { note = "الكلام نظيف — لا توجد اقتراحات." }
            } catch {
                note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }

    private func mark() {
        var wordIndices = Set<Int>()
        var pauseIndices = Set<Int>()
        for suggestion in suggestions where chosen.contains(suggestion.id) {
            if suggestion.kind == .pause {
                pauseIndices.insert(suggestion.startWord)
            } else {
                for index in suggestion.startWord...suggestion.endWord { wordIndices.insert(index) }
            }
        }
        onMark(wordIndices, pauseIndices)
        dismiss()
    }
}
