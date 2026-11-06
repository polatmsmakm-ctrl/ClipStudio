//
//  ThumbnailSheet.swift
//  ClipStudio — Features/Intelligence (Part 6 suggestions)
//
//  Automatic thumbnail: the best frames of the finished edit are found on device
//  (sharpness, light, color, faces); pick one, write the thumbnail text (taken
//  from Content Studio when available), choose position and color, then save
//  the JPEG to Photos and the Exports folder or share it.
//

import SwiftUI

struct ThumbnailSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ThumbnailCandidate] = []
    @State private var selectedID: UUID?
    @State private var text = ""
    @State private var style = ThumbnailStyle()
    @State private var progress: Double?
    @State private var preview: UIImage?
    @State private var shareURL: URL?
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    private var selected: ThumbnailCandidate? { candidates.first { $0.id == selectedID } ?? candidates.first }
    private var outputSize: CGSize { ThumbnailMaker.outputSize(canvas: vm.project.settings.canvasSize) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("معاينة الصورة المصغرة")
                    } else if progress == nil {
                        Button { find() } label: { Label("ابحث عن أفضل الإطارات", systemImage: "sparkle.magnifyingglass").frame(maxWidth: .infinity) }
                            .buttonStyle(.csPrimary)
                            .listRowBackground(Color.clear)
                            .disabled(vm.timeline.isEmpty)
                    }
                    if let progress {
                        HStack {
                            ProgressBarView(progress: progress)
                            Button("إلغاء") { task?.cancel(); self.progress = nil }.font(.caption)
                        }
                    }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.Palette.warning) }
                } footer: {
                    Text("الإطارات من المونتاج النهائي (بالألوان والنصوص). التقييم على جهازك: الوضوح والإضاءة والألوان والوجوه.")
                }
                if !candidates.isEmpty {
                    Section("اختر الإطار") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(candidates.prefix(8)) { candidate in
                                    Button {
                                        selectedID = candidate.id
                                        render()
                                        Haptics.selection()
                                    } label: {
                                        ZStack(alignment: .bottomLeading) {
                                            Image(decorative: candidate.image, scale: 1)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 96, height: 96 * outputSize.height / max(1, outputSize.width))
                                                .clipped()
                                            Text(Fmt.int(Int(candidate.score.rounded())))
                                                .font(.caption2.monospacedDigit().weight(.bold))
                                                .padding(4)
                                                .background(Capsule().fill(.black.opacity(0.6)))
                                                .padding(4)
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(selected?.id == candidate.id ? Theme.Palette.accent : .clear, lineWidth: 2))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("إطار عند " + Fmt.durationPrecise(candidate.time) + "، تقييم " + Fmt.int(Int(candidate.score.rounded())))
                                }
                            }
                        }
                    }
                    Section("النص") {
                        TextField("نص الصورة المصغرة", text: $text, axis: .vertical)
                            .lineLimit(1...3)
                            .onChange(of: text) { _, _ in render() }
                        Picker("المكان", selection: $style.position) {
                            ForEach(ThumbnailTextPosition.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("لون ذهبي", isOn: $style.useAccent)
                        PrecisionSlider(title: "حجم النص", value: $style.size, range: 0.05...0.16, defaultValue: 0.1, step: 0.005,
                                        format: { Fmt.percent($0 / 0.1) })
                        PrecisionSlider(title: "تعتيم الخلفية", value: $style.darken, range: 0...0.8, defaultValue: 0.45, step: 0.05,
                                        format: { Fmt.percent($0) })
                    }
                    .onChange(of: style) { _, _ in render() }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("صورة مصغرة تلقائية")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button { save(share: false) } label: { Label("حفظ في الصور والملفات", systemImage: "square.and.arrow.down") }
                        Button { save(share: true) } label: { Label("مشاركة", systemImage: "square.and.arrow.up") }
                    } label: { Text("حفظ").fontWeight(.semibold) }
                        .disabled(preview == nil)
                }
            }
            .sheet(item: Binding(get: { shareURL.map(ShareFileItem.init) }, set: { shareURL = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .onAppear { if text.isEmpty { text = vm.defaultThumbnailText } }
            .onDisappear { task?.cancel() }
        }
    }

    private func find() {
        error = nil
        progress = 0
        task = Task {
            do {
                candidates = try await vm.thumbnailCandidates { value in progress = value }
                selectedID = candidates.first?.id
                render()
                Haptics.success()
            } catch {
                if !(error is CancellationError) {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            progress = nil
        }
    }

    private func render() {
        guard let selected else { return }
        preview = ThumbnailMaker.compose(frame: selected.image, size: outputSize, text: text, style: style)
    }

    private func save(share: Bool) {
        guard let image = preview else { return }
        do {
            let saved = try ThumbnailMaker.save(image, projectName: vm.project.name)
            if share {
                shareURL = saved.url
            } else {
                Task {
                    do {
                        try await PhotosSaver.saveImage(saved.data)
                        vm.env.toasts.show("حُفظت الصورة المصغرة في الصور وفي مجلد التصدير", style: .success)
                    } catch {
                        vm.env.toasts.show("حُفظت في مجلد التصدير (لم يُسمح بالصور)", style: .warning)
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ShareFileItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
