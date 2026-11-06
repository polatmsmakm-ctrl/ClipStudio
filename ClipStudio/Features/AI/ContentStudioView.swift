//
//  ContentStudioView.swift
//  ClipStudio — Features/AI (Part 5)
//
//  Content Studio: from a project's spoken words (captions / transcripts), its
//  on-screen texts and a few frames, write a title, caption, hashtags, opening
//  hook and thumbnail text for each chosen platform — within each platform's
//  limits. Everything is editable, saved with the project, and can be copied or
//  shared in one tap.
//

import SwiftUI

struct ContentStudioView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let fixedProject: EditProject?
    var showsDone = false

    @State private var projectID: UUID?
    @State private var platforms: Set<SocialPlatform> = [.tiktok, .instagram, .youtubeShorts]
    @State private var tone = "حماسي"
    @State private var postLanguage = "العربية"
    @State private var pack: ContentPack?
    @State private var working = false
    @State private var note: String?
    @State private var consent: AIConsentRequest?
    @State private var shareItem: ShareTextItem?

    init(projectID: UUID?, project: EditProject? = nil, showsDone: Bool = false) {
        fixedProject = project
        self.showsDone = showsDone
        _projectID = State(initialValue: project?.id ?? projectID)
    }

    private var project: EditProject? {
        if let fixedProject { return fixedProject }
        return projectID.flatMap { env.projects.load($0) }
    }

    var body: some View {
        Form {
            if fixedProject == nil {
                Section("المشروع") {
                    Picker("المشروع", selection: $projectID) {
                        Text("اختر").tag(UUID?.none)
                        ForEach(env.projects.summaries) { summary in
                            Text(summary.name).tag(Optional(summary.id))
                        }
                    }
                }
            }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SocialPlatform.allCases) { platform in
                            Button {
                                if platforms.contains(platform) { platforms.remove(platform) } else { platforms.insert(platform) }
                                Haptics.selection()
                            } label: {
                                Label(platform.title, systemImage: platform.symbol)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Capsule().fill(platforms.contains(platform) ? Theme.Palette.accentSoft : Theme.Palette.surfaceRaised))
                                    .overlay(Capsule().strokeBorder(platforms.contains(platform) ? Theme.Palette.accent : Theme.Palette.stroke))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Picker("النبرة", selection: $tone) { ForEach(StoryboardView.tones, id: \.self) { Text($0).tag($0) } }
                Picker("لغة المنشور", selection: $postLanguage) {
                    ForEach(["العربية", "English", "العربية والإنجليزية"], id: \.self) { Text($0).tag($0) }
                }
                Button { generate() } label: {
                    HStack {
                        Label(pack == nil ? "اكتب المحتوى" : "اكتب من جديد", systemImage: "sparkles")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(projectID == nil || platforms.isEmpty || working)
            } header: {
                Text("المنصات")
            } footer: {
                HStack { AIProviderBadge(task: .content); Spacer() }
            }
            if let note { Section { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.Palette.warning) } }
            if let pack {
                if !pack.keywords.isEmpty {
                    Section("الكلمات المفتاحية") {
                        Text(pack.keywords.joined(separator: " • ")).font(.callout)
                    }
                }
                ForEach(pack.posts) { post in
                    postSection(post)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("استوديو المحتوى")
        .keyboardDoneToolbar()
        .toolbar {
            if showsDone { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
        .aiConsent($consent)
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.text]) }
        .onAppear(perform: loadExisting)
        .onChange(of: projectID) { _, _ in loadExisting() }
    }

    private func loadExisting() {
        pack = projectID.flatMap(ContentStore.load)
        note = nil
    }

    private func binding(_ platform: SocialPlatform, _ keyPath: WritableKeyPath<PlatformPost, String>) -> Binding<String> {
        Binding(get: { pack?.posts.first { $0.platform == platform }?[keyPath: keyPath] ?? "" },
                set: { value in
                    guard let index = pack?.posts.firstIndex(where: { $0.platform == platform }) else { return }
                    pack?.posts[index][keyPath: keyPath] = value
                    if let pack { ContentStore.save(pack) }
                })
    }

    private func hashtagBinding(_ platform: SocialPlatform) -> Binding<String> {
        Binding(get: { pack?.posts.first { $0.platform == platform }?.hashtags.map { "#" + $0 }.joined(separator: " ") ?? "" },
                set: { value in
                    guard let index = pack?.posts.firstIndex(where: { $0.platform == platform }) else { return }
                    pack?.posts[index].hashtags = value.split(whereSeparator: { $0 == " " || $0 == "\n" })
                        .map { $0.replacingOccurrences(of: "#", with: "") }.filter { !$0.isEmpty }
                    if let pack { ContentStore.save(pack) }
                })
    }

    private func postSection(_ post: PlatformPost) -> some View {
        Section {
            TextField("العنوان", text: binding(post.platform, \.title), axis: .vertical).font(.headline)
            TextField("الوصف", text: binding(post.platform, \.caption), axis: .vertical).lineLimit(3...10)
            HStack {
                Spacer()
                Text(Fmt.int(post.shareText.count) + " / " + Fmt.int(post.platform.captionLimit))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(post.shareText.count > post.platform.captionLimit ? Theme.Palette.danger : Theme.Palette.textTertiary)
            }
            TextField("الهاشتاقات", text: hashtagBinding(post.platform), axis: .vertical).lineLimit(1...4)
            TextField("خطّاف أول ثانيتين", text: binding(post.platform, \.hook), axis: .vertical)
            TextField("نص الصورة المصغرة", text: binding(post.platform, \.thumbnailText))
            HStack {
                Button {
                    UIPasteboard.general.string = post.shareText
                    Haptics.success()
                    env.toasts.show("نُسخ منشور " + post.platform.title, style: .success)
                } label: { Label("نسخ", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                Spacer()
                Button { shareItem = ShareTextItem(text: post.shareText) } label: { Label("مشاركة", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
        } header: {
            Label(post.platform.title, systemImage: post.platform.symbol)
        }
    }

    private func generate() {
        guard let project else { return }
        let chosen = SocialPlatform.allCases.filter { platforms.contains($0) }
        let input = AIFeatureService.contentInput(project: project, platforms: chosen, tone: tone, language: postLanguage)
        withAIConsent(task: .content, sendsMedia: true,
                      summary: AIFeatureService.uploadSummary(frames: 4, hasText: true, videoSeconds: nil),
                      present: { consent = $0 }) { forceLocal in
            working = true
            let library = env.library
            Task {
                let frames = forceLocal || !AISettings.shared.cloudAvailable ? [] : await AIFeatureService.projectFrames(project, library: library, count: 4)
                do {
                    let result = try await AIFeatureService.content(AIFeatureService.contentRequest(input, frames: frames),
                                                                    platforms: chosen, projectID: project.id, forceLocal: forceLocal)
                    pack = result
                    note = result.provider == .local && AISettings.shared.cloudAvailable && !forceLocal
                        ? "استُخدم المعالج على الجهاز لتعذّر Gemini." : nil
                    if input.spokenText.isEmpty { note = (note.map { $0 + "\n" } ?? "") + "لا يوجد كلام مفرّغ — فرّغ الكلام من «الترجمة التلقائية» لنتيجة أدق." }
                    Haptics.success()
                } catch {
                    env.toasts.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, style: .warning, duration: 3)
                }
                working = false
            }
        }
    }
}

struct ShareTextItem: Identifiable {
    let id = UUID()
    let text: String
}
