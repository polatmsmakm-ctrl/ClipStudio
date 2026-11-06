//
//  MusicSuggestSheet.swift
//  ClipStudio — Features/AI (Part 6 suggestions)
//
//  Suggest music from your library for this project: choose (or let the app
//  derive) a mood, the songs are analyzed on device (BPM, energy, length — once
//  per file, cached) and ranked with reasons. Listen, then add one to a music
//  track with its ending fitted to the picture.
//

import SwiftUI
import AVFoundation

struct MusicSuggestSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var moodID = ""
    @State private var suggestions: [MusicSuggestion] = []
    @State private var progress: Double?
    @State private var status = ""
    @State private var skipped = 0
    @State private var fit = true
    @State private var player: AVAudioPlayer?
    @State private var playingID: UUID?
    @State private var control: RenderControl?
    @State private var task: Task<Void, Never>?

    private var songs: [MediaAsset] {
        vm.env.library.assets.filter { $0.kind == .audio && !vm.env.library.isMissing($0) && ($0.durationSeconds ?? 0) >= 5 }
    }

    private var mood: MusicMood { MusicMood.mood(moodID) ?? vm.suggestedMood() }

    var body: some View {
        NavigationStack {
            Group {
                if songs.isEmpty {
                    EmptyStateView(systemImage: "music.note.list", title: "لا توجد أغانٍ في المكتبة",
                                   message: "استورد ملفات صوتية إلى المكتبة (من الملفات أو استخرج الصوت من فيديو) ثم ارجع هنا.")
                } else {
                    form
                }
            }
            .screenBackground()
            .navigationTitle("اقتراح موسيقى")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { stopAll(); dismiss() } }
            }
            .onAppear {
                if moodID.isEmpty { moodID = vm.suggestedMood().id }
            }
            .onDisappear { stopAll() }
        }
    }

    private var form: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MusicMood.all) { item in
                            ChipButton(title: item.title, isSelected: moodID == item.id) {
                                moodID = item.id
                                rerank()
                            }
                        }
                    }
                }
                LabeledContent("الهدف", value: Fmt.int(Int(mood.bpm)) + " BPM تقريبًا • طاقة " + Fmt.percent(mood.energy))
                Toggle("ملاءمة النهاية مع الفيديو", isOn: $fit)
                Button { analyze() } label: {
                    HStack {
                        Label(suggestions.isEmpty ? "حلّل " + Fmt.int(songs.count) + " أغنية واقترح" : "حدّث الاقتراحات", systemImage: "wand.and.stars")
                        Spacer()
                        if progress != nil { ProgressView() }
                    }
                }
                .disabled(progress != nil)
                if let progress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status).font(.caption)
                        HStack {
                            ProgressBarView(progress: progress)
                            Button("إلغاء") { control?.cancel(); task?.cancel() }.font(.caption)
                        }
                    }
                }
            } header: {
                Text("المزاج")
            } footer: {
                Text("التحليل على جهازك ويُحفظ لكل ملف، فالمرة الثانية فورية. المزاج المقترح من إيقاع المونتاج واسم المشروع.")
            }
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions.prefix(10)) { suggestion in
                        row(suggestion)
                    }
                } header: {
                    Text("الأنسب لمشروعك")
                } footer: {
                    if skipped > 0 { Text("تعذّر تحليل " + Fmt.int(skipped) + " ملف (قصير جدًا أو بلا إيقاع).") }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ suggestion: MusicSuggestion) -> some View {
        HStack(spacing: 10) {
            Button { togglePlay(suggestion.asset) } label: {
                Image(systemName: playingID == suggestion.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playingID == suggestion.id ? "إيقاف" : "استماع")
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.asset.displayName).lineLimit(1)
                Text(suggestion.reasons.joined(separator: " • ")).font(.caption2).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                Text(Fmt.int(Int(suggestion.analysis.bpm.rounded())) + " BPM • " + Fmt.duration(suggestion.analysis.duration))
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
            VStack(spacing: 6) {
                Text(Fmt.int(Int(suggestion.score.rounded()))).font(.headline.monospacedDigit()).foregroundStyle(Theme.Palette.accent)
                Button("أضف") {
                    stopAll()
                    vm.addSuggestedMusic(suggestion, fit: fit)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func analyze() {
        let items = songs
        let library = vm.env.library
        let control = RenderControl()
        self.control = control
        progress = 0
        skipped = 0
        task = Task {
            var analyzed: [(asset: MediaAsset, analysis: MusicAnalysis)] = []
            var failed = 0
            for (index, asset) in items.enumerated() {
                if control.isCancelled || Task.isCancelled { break }
                status = "تحليل «" + asset.displayName + "» (" + Fmt.int(index + 1) + "/" + Fmt.int(items.count) + ")"
                if let cached = MusicAnalyzer.cached(assetID: asset.id) {
                    analyzed.append((asset: asset, analysis: cached))
                } else if let url = library.url(forID: asset.id) {
                    let base = Double(index) / Double(items.count)
                    let relay = ProgressRelay { value in progress = base + value / Double(items.count) }
                    do {
                        let result = try await MusicAnalyzer.analyze(assetID: asset.id, url: url, control: control,
                                                                     progress: { relay.send($0) })
                        analyzed.append((asset: asset, analysis: result))
                    } catch {
                        failed += 1
                    }
                }
                progress = Double(index + 1) / Double(items.count)
            }
            cache = analyzed
            skipped = failed
            rerank()
            progress = nil
            if !analyzed.isEmpty { Haptics.success() }
        }
    }

    @State private var cache: [(asset: MediaAsset, analysis: MusicAnalysis)] = []

    private func rerank() {
        guard !cache.isEmpty else { return }
        suggestions = MusicRecommender.rank(cache, mood: mood, projectDuration: vm.pictureEnd)
    }

    private func togglePlay(_ asset: MediaAsset) {
        if playingID == asset.id {
            stopAll()
            return
        }
        stopAll()
        guard let url = vm.env.library.url(forID: asset.id) else { return }
        if vm.player.isPlaying { vm.player.pause() }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        if let audio = try? AVAudioPlayer(contentsOf: url) {
            audio.currentTime = min(30, max(0, (asset.durationSeconds ?? 0) * 0.3))
            audio.play()
            player = audio
            playingID = asset.id
        }
    }

    private func stopAll() {
        player?.stop()
        player = nil
        playingID = nil
    }
}
