//
//  HookCheckSheet.swift
//  ClipStudio — Features/AI (Part 6 suggestions)
//
//  Pre-publish check: is the hook strong in the first seconds? The opening is
//  measured on device; Gemini also sees six small frames of the first 3 seconds
//  (after consent). Shows a score, strengths, problems and suggestions — some
//  with a one-tap fix (title at the start, cut a slow start), each one undoable.
//

import SwiftUI

struct HookCheckSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: HookReport?
    @State private var provider: AIProviderKind?
    @State private var note: String?
    @State private var working = false
    @State private var applied: Set<UUID> = []
    @State private var consent: AIConsentRequest?
    @State private var useLocal = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        if useLocal { StatusPill(text: "على الجهاز", systemImage: "iphone") } else { AIProviderBadge(task: .hookCheck) }
                        Spacer()
                        Toggle("على الجهاز", isOn: $useLocal).labelsHidden().fixedSize()
                    }
                    Button { run() } label: {
                        HStack {
                            Label(report == nil ? "افحص البداية" : "افحص من جديد", systemImage: "bolt.badge.clock")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || vm.timeline.isEmpty)
                    if let note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.Palette.warning) }
                } footer: {
                    Text("يقيس النص الأول والكلام الأول والقطعات والصوت في أول الثواني. مع Gemini تُرسل 6 صور صغيرة من أول 3 ثوانٍ.")
                }
                if let report {
                    Section {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().stroke(Theme.Palette.surfaceRaised, lineWidth: 8)
                                Circle().trim(from: 0, to: report.score / 100)
                                    .stroke(color(report.score), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                Text(Fmt.int(Int(report.score.rounded()))).font(.title2.monospacedDigit().weight(.bold))
                            }
                            .frame(width: 72, height: 72)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("الدرجة " + Fmt.int(Int(report.score.rounded())) + " من 100")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(report.grade).font(.headline).foregroundStyle(color(report.score))
                                Text(report.verdict).font(.callout)
                                if let provider { Text(provider.title).font(.caption2).foregroundStyle(Theme.Palette.textTertiary) }
                            }
                        }
                    }
                    if !report.strengths.isEmpty {
                        Section("نقاط القوة") {
                            ForEach(report.strengths, id: \.self) { Label($0, systemImage: "checkmark.circle").foregroundStyle(Theme.Palette.success) }
                        }
                    }
                    if !report.problems.isEmpty {
                        Section("مشاكل") {
                            ForEach(report.problems, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(Theme.Palette.warning) }
                        }
                    }
                    if !report.suggestions.isEmpty {
                        Section("اقتراحات") {
                            ForEach(report.suggestions) { suggestion in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(suggestion.text)
                                    if suggestion.action != .none {
                                        HStack {
                                            Text(actionTitle(suggestion)).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                                            Spacer()
                                            if applied.contains(suggestion.id) {
                                                Label("تم", systemImage: "checkmark").font(.caption).foregroundStyle(Theme.Palette.success)
                                            } else {
                                                Button("طبّق") {
                                                    Task {
                                                        await vm.applyHookSuggestion(suggestion)
                                                        applied.insert(suggestion.id)
                                                    }
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .controlSize(.small)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("فحص الخطّاف")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
            .aiConsent($consent)
        }
    }

    private func color(_ score: Double) -> Color {
        score >= 70 ? Theme.Palette.success : score >= 45 ? Theme.Palette.accent : Theme.Palette.warning
    }

    private func actionTitle(_ suggestion: HookSuggestion) -> String {
        switch suggestion.action {
        case .addTitle: "عنوان: «" + suggestion.titleText + "»"
        case .trimStart: "حذف أول " + Fmt.seconds(suggestion.trimTo, digits: 1)
        case .none: ""
        }
    }

    private func run() {
        let local = useLocal
        withAIConsent(task: .hookCheck, sendsMedia: !local,
                      summary: AIFeatureService.uploadSummary(frames: HookAnalyzer.frameTimes.count, hasText: true, videoSeconds: nil),
                      present: { consent = $0 }) { forceLocal in
            working = true
            note = nil
            applied = []
            let input = vm.hookInput()
            Task {
                let useCloud = !(forceLocal || local) && AISettings.shared.cloudAvailable
                let frames = useCloud ? await vm.hookFrames() : []
                do {
                    let result = try await HookAnalyzer.check(input, frames: frames, forceLocal: forceLocal || local)
                    report = result.report
                    provider = result.response.provider
                    note = result.response.note
                    Haptics.success()
                } catch {
                    report = HookAnalyzer.local(input)
                    provider = .local
                    note = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) + " — النتيجة من الفحص على الجهاز."
                }
                working = false
            }
        }
    }
}
