//
//  ColorLibraryPanels.swift
//  ClipStudio — Features/Color
//
//  LUT picker (with .cube import and live thumbnails on the clip's frame), looks
//  (built-in + saved presets, save current grade), shot matching against another
//  clip, and the LUT library screen reachable from Settings.
//

import SwiftUI
import UniformTypeIdentifiers
import CoreImage

private let cubeType: UTType = UTType(filenameExtension: "cube") ?? .data

// MARK: - Thumbnails

@MainActor
@Observable
final class GradeThumbnailCache {
    private(set) var images: [String: UIImage] = [:]
    private var baseStamp: ObjectIdentifier?

    func reset(for base: CIImage?) {
        let stamp = base.map { ObjectIdentifier($0) }
        if stamp != baseStamp {
            images = [:]
            baseStamp = stamp
        }
    }

    func render(key: String, base: CIImage, color: ColorAdjustments, lut: LUTReference?) async {
        guard images[key] == nil else { return }
        await Task.yield()
        let small = FramePreviewRenderer.shared.downscaled(base, maxDimension: 220)
        let graded = FramePreviewRenderer.shared.graded(small, color: color, lut: lut)
        if let image = FramePreviewRenderer.shared.uiImage(graded) { images[key] = image }
    }
}

struct GradeTile: View {
    let title: String
    let image: UIImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Theme.Palette.surfaceHighlight
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.Palette.accent : .clear, lineWidth: 2))
            Text(title).font(.caption2).lineLimit(1)
        }
        .foregroundStyle(Theme.Palette.textPrimary)
    }
}

// MARK: - LUT picker

struct LUTPickerPanel: View {
    let vm: StudioViewModel
    let clipID: UUID
    let base: CIImage?

    @State private var cache = GradeThumbnailCache()
    @State private var showImporter = false

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }
    private var library: LUTLibrary { vm.env.lutLibrary }

    var body: some View {
        if let clip = editor.clip {
            InspectorSection(title: "جداول الألوان LUT", systemImage: "cube",
                             trailing: AnyView(Button { showImporter = true } label: { Label("استيراد .cube", systemImage: "plus") }.font(.caption))) {
                if library.luts.isEmpty {
                    Text("استورد ملفات .cube (3D LUT) من تطبيق الملفات لتطبيقها على مقاطعك.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 10) {
                    Button {
                        editor.update("إزالة LUT", key: "lut") { $0.lut = nil }
                        vm.endContinuousEdit()
                    } label: {
                        GradeTile(title: "بدون", image: cache.images["none"], isSelected: clip.lut == nil)
                    }
                    .buttonStyle(.plain)
                    ForEach(library.luts) { info in
                        Button {
                            editor.update("LUT: " + info.name, key: "lut") { $0.lut = LUTReference(lutID: info.id, intensity: $0.lut?.intensity ?? 1) }
                            vm.endContinuousEdit()
                        } label: {
                            GradeTile(title: info.name, image: cache.images[info.id.uuidString], isSelected: clip.lut?.lutID == info.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if clip.lut != nil {
                    PrecisionSlider(title: "شدة LUT", value: editor.binding("شدة LUT", key: "lut-intensity",
                                                                            read: { $0.lut?.intensity ?? 1 },
                                                                            write: { clip, value in clip.lut?.intensity = value }),
                                    range: 0...1, defaultValue: 1,
                                    format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                                    onEditingChanged: editor.editingChanged)
                }
            }
            .task(id: thumbnailsKey(clip)) { await renderThumbnails(clip) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [cubeType], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task {
                        let report = await library.importFiles(urls)
                        vm.env.toasts.show(report.summary, style: report.failures.isEmpty ? .success : .warning)
                    }
                case .failure(let error):
                    vm.env.toasts.show(error.localizedDescription, style: .error)
                }
            }
        }
    }

    private func thumbnailsKey(_ clip: Clip) -> String {
        String(clip.color.hashValue) + "-" + String(library.luts.count) + "-" + String(base != nil)
    }

    private func renderThumbnails(_ clip: Clip) async {
        guard let base else { return }
        cache.reset(for: base)
        await cache.render(key: "none", base: base, color: clip.color, lut: nil)
        for info in library.luts {
            if Task.isCancelled { return }
            await cache.render(key: info.id.uuidString, base: base, color: clip.color, lut: LUTReference(lutID: info.id, intensity: 1))
        }
    }
}

// MARK: - Looks

struct ColorLooksPanel: View {
    let vm: StudioViewModel
    let clipID: UUID
    let base: CIImage?

    @State private var cache = GradeThumbnailCache()
    @State private var saving = false
    @State private var presetName = ""

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }
    private var store: ColorPresetStore { vm.env.colorPresets }

    var body: some View {
        if let clip = editor.clip {
            InspectorSection(title: "المظاهر", systemImage: "camera.filters",
                             trailing: AnyView(Button { presetName = ""; saving = true } label: {
                                 Label("حفظ الحالي", systemImage: "square.and.arrow.down")
                             }.font(.caption))) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 10) {
                    ForEach(store.all) { preset in
                        Button {
                            editor.update("مظهر: " + preset.name, key: "look") { c in
                                c.color = preset.adjustments
                                if let lut = preset.lut { c.lut = lut }
                            }
                            vm.endContinuousEdit()
                        } label: {
                            GradeTile(title: preset.name, image: cache.images[preset.id.uuidString],
                                      isSelected: clip.color == preset.adjustments)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !preset.isBuiltIn {
                                Button(role: .destructive) { store.delete(preset.id) } label: { Label("حذف", systemImage: "trash") }
                            }
                        }
                    }
                }
                Text("المظهر يستبدل إعدادات الألوان الحالية — يمكنك التراجع في أي وقت.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .task(id: String(store.all.count) + "-" + String(base != nil)) { await renderThumbnails() }
            .alert("حفظ المظهر", isPresented: $saving) {
                TextField("اسم المظهر", text: $presetName)
                Button("حفظ") {
                    store.save(name: presetName, adjustments: clip.color, lut: clip.lut)
                    vm.env.toasts.show("تم حفظ المظهر", style: .success)
                }
                Button("إلغاء", role: .cancel) {}
            }
        }
    }

    private func renderThumbnails() async {
        guard let base else { return }
        cache.reset(for: base)
        for preset in store.all {
            if Task.isCancelled { return }
            await cache.render(key: preset.id.uuidString, base: base, color: preset.adjustments, lut: preset.lut)
        }
    }
}

// MARK: - Shot matching

struct ColorMatchPanel: View {
    let vm: StudioViewModel
    let clipID: UUID
    let base: CIImage?

    @State private var referenceID: UUID?
    @State private var strength: Double = 1
    @State private var result: ColorMatcher.Result?
    @State private var preview: UIImage?
    @State private var working = false

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    private var candidates: [Clip] {
        vm.timeline.tracks.filter { $0.kind.isVisual }.flatMap { track in
            track.clips.filter { clip in
                guard clip.id != clipID else { return false }
                switch clip.source {
                case .media, .image, .freezeFrame: return true
                default: return false
                }
            }
        }
        .sorted { $0.start < $1.start }
    }

    var body: some View {
        if let clip = editor.clip {
            InspectorSection(title: "مطابقة لقطة مع أخرى", systemImage: "eyedropper.halffull") {
                Text("اختر اللقطة المرجعية؛ يُحسب التعريض والتباين والتشبّع وتوازن الألوان لتطابقها.")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if candidates.isEmpty {
                    Text("لا توجد لقطات أخرى في الخط الزمني.").font(.caption).foregroundStyle(Theme.Palette.warning)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(candidates) { candidate in
                            Button {
                                referenceID = candidate.id
                                Task { await compute(target: clip) }
                            } label: {
                                VStack(spacing: 4) {
                                    Group {
                                        if let asset = vm.asset(for: candidate) {
                                            MediaThumbnailView(source: .asset(asset, vm.env.library.url(for: asset),
                                                                              SpeedMapping.sourceTime(of: candidate, local: candidate.duration.seconds / 2) ?? 1))
                                        } else {
                                            Theme.Palette.surfaceHighlight
                                        }
                                    }
                                    .frame(width: 96, height: 56)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .strokeBorder(referenceID == candidate.id ? Theme.Palette.accent : .clear, lineWidth: 2))
                                    Text(candidate.name).font(.caption2).lineLimit(1).frame(width: 96)
                                }
                                .foregroundStyle(Theme.Palette.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if working {
                    ProgressView().tint(Theme.Palette.accent)
                }
                if let result {
                    if let preview {
                        Image(uiImage: preview).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    PrecisionSlider(title: "قوة المطابقة", value: $strength, range: 0...1, defaultValue: 1,
                                    format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100) { editing in
                        if !editing { Task { await compute(target: clip) } }
                    }
                    HStack {
                        StatBadge(title: "السطوع المرجعي", value: Fmt.percent(result.reference.lumaMean))
                        StatBadge(title: "بعد المطابقة", value: Fmt.percent(result.after.lumaMean))
                    }
                    Button {
                        let adjustments = result.adjustments
                        editor.update("مطابقة الألوان", key: "match") { $0.color = adjustments }
                        vm.endContinuousEdit()
                        vm.env.toasts.show("تم تطبيق المطابقة", style: .success)
                    } label: {
                        Label("تطبيق المطابقة", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.csPrimary)
                }
            }
        }
    }

    private func compute(target clip: Clip) async {
        guard let referenceID, let reference = TimelineEngine.clip(referenceID, in: vm.timeline), let base else { return }
        working = true
        defer { working = false }
        guard let referenceFrame = await vm.gradedFrame(for: reference, maxDimension: 320) else {
            vm.env.toasts.show("تعذّر قراءة اللقطة المرجعية", style: .warning)
            return
        }
        let target = FramePreviewRenderer.shared.downscaled(base, maxDimension: 320)
        guard let matched = ColorMatcher.match(reference: referenceFrame, target: target, starting: clip.color, strength: strength) else {
            return
        }
        result = matched
        let graded = FramePreviewRenderer.shared.graded(FramePreviewRenderer.shared.downscaled(base, maxDimension: 640),
                                                         color: matched.adjustments, lut: clip.lut)
        preview = FramePreviewRenderer.shared.uiImage(graded)
    }
}

// MARK: - LUT library (Settings)

struct LUTLibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showImporter = false
    @State private var pendingDelete: LUTInfo?
    @State private var usage: [String] = []

    var body: some View {
        List {
            Section {
                if env.lutLibrary.luts.isEmpty {
                    EmptyStateView(systemImage: "cube", title: "لا توجد جداول ألوان",
                                   message: "استورد ملفات .cube لتستخدمها في مساحة الألوان.",
                                   actionTitle: "استيراد") { showImporter = true }
                        .listRowBackground(Color.clear)
                }
                ForEach(env.lutLibrary.luts) { info in
                    HStack {
                        Image(systemName: "cube.fill").foregroundStyle(Theme.Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.name).font(.subheadline.weight(.semibold))
                            Text("3D • " + Fmt.int(info.size) + "³ • " + Fmt.shortDate(info.importedAt))
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            usage = env.lutLibrary.usage(of: info.id, projects: env.projects)
                            pendingDelete = info
                        } label: { Label("حذف", systemImage: "trash") }
                    }
                    .listRowBackground(Theme.Palette.surface.opacity(0.7))
                }
            } footer: {
                Text("يدعم ClipStudio ملفات .cube ثلاثية الأبعاد (حتى 65³). تُحفظ داخل التطبيق وتُضمّن في النسخ الاحتياطي.")
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("جداول الألوان LUT")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("استيراد", systemImage: "plus") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [cubeType], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task {
                    let report = await env.lutLibrary.importFiles(urls)
                    env.toasts.show(report.summary, style: report.failures.isEmpty ? .success : .warning)
                }
            case .failure(let error):
                env.toasts.show(error.localizedDescription, style: .error)
            }
        }
        .confirmationDialog(pendingDelete.map { "حذف «" + $0.name + "»؟" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                if let info = pendingDelete { env.lutLibrary.delete(info.id) }
                pendingDelete = nil
            }
        } message: {
            Text(usage.isEmpty ? "لا يستخدمه أي مشروع." : "مستخدم في: " + usage.joined(separator: "، ") + " — ستعود المقاطع بدون LUT.")
        }
    }
}
