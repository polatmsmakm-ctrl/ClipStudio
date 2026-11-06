//
//  VoiceoverGeneratorSheet.swift
//  ClipStudio — Features/AI (Part 6 suggestions)
//
//  Generated voiceover in the Studio: type (or take from the selected title) the
//  text, choose a device voice (offline) or a Gemini voice (text only is sent),
//  listen, then place it on a voiceover track at the playhead.
//

import SwiftUI
import AVFoundation

/// Voice settings shared by the Studio sheet and the storyboard.
struct VoiceoverOptionsSection: View {
    @Binding var options: VoiceoverOptions
    @State private var settings = AISettings.shared

    private var languages: [String] {
        let available = Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))
        let preferred = SpeechSynthesis.preferredLanguages.filter { available.contains($0) }
        let others = available.subtracting(preferred).sorted()
        return preferred + others
    }

    var body: some View {
        Section {
            Picker("المحرك", selection: $options.engine) {
                ForEach(VoiceoverEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: options.engine) { _, engine in
                if engine == .gemini && !settings.cloudAvailable { options.engine = .device }
            }
            if options.engine == .device {
                Picker("اللغة", selection: $options.language) {
                    ForEach(languages, id: \.self) { code in
                        Text(Locale(identifier: "ar").localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                .onChange(of: options.language) { _, _ in options.deviceVoice = nil }
                Picker("الصوت", selection: $options.deviceVoice) {
                    Text("الأفضل المتاح").tag(String?.none)
                    ForEach(SpeechSynthesis.deviceVoices(language: options.language), id: \.identifier) { voice in
                        Text(SpeechSynthesis.voiceTitle(voice)).tag(Optional(voice.identifier))
                    }
                }
                PrecisionSlider(title: "السرعة", value: $options.rate, range: 0.3...0.65, defaultValue: 0.5, step: 0.01,
                                format: { Fmt.percent($0 / 0.5) })
                PrecisionSlider(title: "طبقة الصوت", value: $options.pitch, range: 0.7...1.4, defaultValue: 1, step: 0.01,
                                format: { Fmt.number($0, digits: 2) })
            } else {
                Picker("الصوت", selection: $options.geminiVoice) {
                    ForEach(SpeechSynthesis.geminiVoices, id: \.id) { voice in
                        Text(voice.title).tag(voice.id)
                    }
                }
                TextField("أسلوب الإلقاء (اختياري): بنبرة حماسية…", text: $options.style)
            }
        } header: {
            Text("الصوت")
        } footer: {
            Text(options.engine == .device
                 ? "أصوات Apple على جهازك — بدون إنترنت. للحصول على أصوات أوضح نزّل الأصوات المحسّنة من الإعدادات › تسهيلات الاستخدام › المحتوى المنطوق."
                 : "يُرسل النص فقط إلى Gemini (بدون صور أو صوت). " + (settings.cloudAvailable ? "" : "يلزم مفتاح Gemini."))
        }
    }
}

struct VoiceoverGeneratorSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var options = VoiceoverOptions()
    @State private var working = false
    @State private var previewURL: URL?
    @State private var previewText = ""
    @State private var player: AVAudioPlayer?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("نص التعليق الصوتي…", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                    if let selected = selectedText, selected != text {
                        Button { text = selected } label: { Label("استخدم نص العنوان المحدد", systemImage: "text.quote") }
                    }
                } header: {
                    Text("النص")
                } footer: {
                    Text(Fmt.int(text.count) + " حرف • يُضاف عند رأس التشغيل " + Fmt.timecode(vm.currentTime, fps: vm.frameRate))
                }
                VoiceoverOptionsSection(options: $options)
                Section {
                    Button { preview() } label: {
                        HStack {
                            Label(player?.isPlaying == true ? "إيقاف" : "استمع", systemImage: player?.isPlaying == true ? "stop.fill" : "play.fill")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.Palette.warning) }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("تعليق صوتي من نص")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { stopAndDismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("أضف") { add() }
                        .fontWeight(.semibold)
                        .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if text.isEmpty, let selectedText { text = selectedText } }
            .onDisappear { player?.stop(); task?.cancel() }
            .onChange(of: options) { _, _ in invalidatePreview() }
            .onChange(of: text) { _, _ in invalidatePreview() }
        }
    }

    private var selectedText: String? {
        guard let id = vm.selection.first, let clip = TimelineEngine.clip(id, in: vm.timeline), case .text(let content) = clip.source else { return nil }
        let value = content.caption?.composedText ?? content.text
        return value.isEmpty ? nil : value
    }

    private func invalidatePreview() {
        player?.stop()
        player = nil
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        previewURL = nil
    }

    private func synthesize() async throws -> URL {
        if let previewURL, previewText == text { return previewURL }
        let url = try await SpeechSynthesis.synthesize(text, options: options)
        previewURL = url
        previewText = text
        return url
    }

    private func preview() {
        if player?.isPlaying == true {
            player?.stop()
            player = nil
            return
        }
        working = true
        error = nil
        task = Task {
            do {
                let url = try await synthesize()
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                let audio = try AVAudioPlayer(contentsOf: url)
                audio.play()
                player = audio
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }

    private func add() {
        working = true
        error = nil
        player?.stop()
        let time = vm.currentTime
        task = Task {
            do {
                let url = try await synthesize()
                vm.placeVoiceover(fileURL: url, at: time, duration: 0)
                previewURL = nil
                Haptics.success()
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }

    private func stopAndDismiss() {
        player?.stop()
        task?.cancel()
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        dismiss()
    }
}
