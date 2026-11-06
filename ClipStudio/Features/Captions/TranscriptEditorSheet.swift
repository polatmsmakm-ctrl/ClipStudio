//
//  TranscriptEditorSheet.swift
//  ClipStudio — Features/Captions (Part 3)
//
//  Text-based editing (foundation): the spoken words of the chosen tracks laid out
//  as text. Tap a word to jump there; switch to "mark" mode to select words and
//  long pauses, mark filler words or pauses automatically, then delete them — the
//  timeline is cut and closed on every unlocked track in one undoable step.
//  Part 5: "اقتراحات الذكاء" proposes fillers, repetitions, stumbles and pauses
//  (Gemini or on device) and marks the accepted ones here.
//

import SwiftUI

struct TranscriptEditorSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("captions.locale") private var localeID = "ar-SA"
    @AppStorage("captions.allowServer") private var allowServer = false
    @State private var sources: Set<UUID> = []
    @State private var words: [TimelineWord] = []
    @State private var markedWords: Set<Int> = []
    @State private var markedPauses: Set<Int> = []
    @State private var marking = false
    @State private var pauseThreshold = 1.0
    @State private var loaded = false
    @State private var showAISuggestions = false

    private struct Token: Identifiable {
        enum Kind { case word, pause }
        let id: String
        let kind: Kind
        let index: Int
        let text: String
        let width: CGFloat
    }

    private var tokens: [Token] {
        let font = UIFont.preferredFont(forTextStyle: .body)
        var result: [Token] = []
        for (index, word) in words.enumerated() {
            let width = (word.text as NSString).size(withAttributes: [.font: font]).width + 18
            result.append(Token(id: "w" + String(index), kind: .word, index: index, text: word.text, width: ceil(width)))
            if index + 1 < words.count {
                let gap = words[index + 1].start - word.end
                if gap >= pauseThreshold {
                    let label = "⏸ " + Fmt.seconds(gap, digits: 1)
                    let w = (label as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .caption1)]).width + 16
                    result.append(Token(id: "p" + String(index), kind: .pause, index: index, text: label, width: ceil(w)))
                }
            }
        }
        return result
    }

    private var markedCount: Int { markedWords.count + markedPauses.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.Palette.stroke)
                if words.isEmpty {
                    emptyState
                } else {
                    GeometryReader { geo in
                        ScrollView {
                            flow(width: geo.size.width - 32)
                                .padding(16)
                        }
                    }
                }
                if !words.isEmpty { bottomBar }
            }
            .navigationTitle("التعديل بالنص")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() }.fontWeight(.semibold) }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAISuggestions = true } label: { Label("اقتراحات الذكاء", systemImage: "sparkles") }
                        .disabled(words.isEmpty)
                }
            }
            .sheet(isPresented: $showAISuggestions) {
                TranscriptAISuggestionsSheet(vm: vm, words: words) { wordIndices, pauseIndices in
                    marking = true
                    markedWords.formUnion(wordIndices)
                    markedPauses.formUnion(pauseIndices)
                }
            }
            .screenBackground()
            .onAppear {
                guard !loaded else { return }
                loaded = true
                sources = vm.defaultCaptionSources()
                reload()
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("اللغة", selection: $localeID) {
                    ForEach(TranscriptionLanguage.available) { Text($0.title).tag($0.id) }
                }
            } label: {
                Label(TranscriptionLanguage.all.first { $0.id == localeID }?.title ?? localeID, systemImage: "globe")
                    .font(.caption.weight(.semibold))
            }
            .onChange(of: localeID) { reload() }
            Menu {
                ForEach(vm.captionSourceTracks) { pair in
                    Button {
                        if sources.contains(pair.track.id) { sources.remove(pair.track.id) } else { sources.insert(pair.track.id) }
                        reload()
                    } label: {
                        Label(pair.track.name, systemImage: sources.contains(pair.track.id) ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                Label("المسارات (" + Fmt.int(sources.count) + ")", systemImage: "square.stack.3d.up").font(.caption.weight(.semibold))
            }
            Spacer()
            Toggle(isOn: $marking) {
                Label("تحديد", systemImage: "strikethrough")
            }
            .toggleStyle(.button)
            .tint(Theme.Palette.danger)
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            let pending = vm.untranscribedSeconds(localeID: localeID, sourceTrackIDs: sources)
            EmptyStateView(systemImage: "text.quote", title: "لا يوجد نص بعد",
                           message: pending > 0.5 ? "فرّغ الكلام (" + Fmt.durationPrecise(pending) + ") لتعديل الفيديو بحذف الكلمات والوقفات."
                                                  : "لا يوجد كلام في المسارات المختارة.")
            if pending > 0.5 {
                if !TranscriptionService.supportsOnDevice(localeID) && !allowServer {
                    Text("هذه اللغة تحتاج خوادم Apple في جهازك — فعّل السماح بها من شاشة الترجمة التلقائية.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.warning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Button {
                    vm.transcribeSources(localeID: localeID, allowServer: allowServer, sourceTrackIDs: sources, range: nil) { result in
                        words = result
                        markedWords = []
                        markedPauses = []
                    }
                } label: {
                    Label("تفريغ الكلام", systemImage: "waveform.and.mic").frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .foregroundStyle(Color(hex: 0x1A1408))
                .disabled(sources.isEmpty)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func flow(width: CGFloat) -> some View {
        let rows = layoutRows(width: max(80, width))
        let current = vm.currentTime
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 6) {
                    ForEach(rows[rowIndex]) { token in
                        chip(token, current: current)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func layoutRows(width: CGFloat) -> [[Token]] {
        var rows: [[Token]] = []
        var row: [Token] = []
        var used: CGFloat = 0
        for token in tokens {
            let needed = token.width + (row.isEmpty ? 0 : 6)
            if used + needed > width && !row.isEmpty {
                rows.append(row)
                row = []
                used = 0
            }
            row.append(token)
            used += token.width + (row.count > 1 ? 6 : 0)
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    @ViewBuilder
    private func chip(_ token: Token, current: Double) -> some View {
        switch token.kind {
        case .word:
            let word = words[token.index]
            let marked = markedWords.contains(token.index)
            let playing = current >= word.start && current < word.end
            let filler = CaptionBuilder.isFiller(word.text)
            Text(token.text)
                .font(.body)
                .strikethrough(marked, color: Theme.Palette.danger)
                .foregroundStyle(marked ? Theme.Palette.danger : (word.confidence > 0 && word.confidence < 0.4 ? Theme.Palette.warning : Theme.Palette.textPrimary))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(
                    playing ? Theme.Palette.accentSoft : (filler ? Theme.Palette.warning.opacity(0.15) : Theme.Palette.surfaceHighlight.opacity(0.6))))
                .onTapGesture {
                    if marking {
                        if marked { markedWords.remove(token.index) } else { markedWords.insert(token.index) }
                        Haptics.selection()
                    } else {
                        vm.seek(to: word.start + 0.01)
                    }
                }
                .accessibilityLabel(word.text + (marked ? "، محددة للحذف" : ""))
        case .pause:
            let marked = markedPauses.contains(token.index)
            Text(token.text)
                .font(.caption)
                .strikethrough(marked, color: Theme.Palette.danger)
                .foregroundStyle(marked ? Theme.Palette.danger : Theme.Palette.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Capsule().strokeBorder(Theme.Palette.stroke))
                .onTapGesture {
                    if marking {
                        if marked { markedPauses.remove(token.index) } else { markedPauses.insert(token.index) }
                        Haptics.selection()
                    } else {
                        vm.seek(to: words[token.index].end)
                    }
                }
                .accessibilityLabel("وقفة")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("الوقفات الأطول من").font(.caption)
                Slider(value: $pauseThreshold, in: 0.3...3, step: 0.1)
                Text(Fmt.seconds(pauseThreshold, digits: 1)).font(.caption.monospacedDigit())
            }
            HStack(spacing: 8) {
                Button("الكلمات الحشو") {
                    marking = true
                    for (index, word) in words.enumerated() where CaptionBuilder.isFiller(word.text) { markedWords.insert(index) }
                }
                Button("كل الوقفات") {
                    marking = true
                    for token in tokens where token.kind == .pause { markedPauses.insert(token.index) }
                }
                Button("مسح") {
                    markedWords = []
                    markedPauses = []
                }
                .disabled(markedCount == 0)
                Spacer()
                Button(role: .destructive) {
                    applyDeletion()
                } label: {
                    Label("حذف (" + Fmt.int(markedCount) + ")", systemImage: "scissors")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.danger)
                .disabled(markedCount == 0)
            }
            .buttonStyle(.bordered)
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Theme.Palette.surface)
    }

    // MARK: Actions

    private func reload() {
        words = vm.cachedTimelineWords(localeID: localeID, sourceTrackIDs: sources)
        markedWords = []
        markedPauses = []
    }

    private func applyDeletion() {
        let pad = 0.02
        var spans: [TimeSpan] = markedWords.map { index in
            let word = words[index]
            // A little padding around the word, never cutting into its neighbours.
            let previousEnd = index > 0 ? words[index - 1].end : word.start - pad
            let nextStart = index + 1 < words.count ? words[index + 1].start : word.end + pad
            return TimeSpan(start: max(previousEnd, word.start - pad), end: min(nextStart, word.end + pad))
        }
        for index in markedPauses where index + 1 < words.count {
            let start = words[index].end + 0.12
            let end = words[index + 1].start - 0.12
            if end > start { spans.append(TimeSpan(start: start, end: end)) }
        }
        vm.removeTimelineRanges(spans, name: "حذف من النص")
        reload()
    }
}
