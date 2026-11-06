//
//  StudioView.swift
//  ClipStudio — Features/ProStudio
//
//  Full-screen Pro Studio editor.
//  • iPad / regular width: resizable multi-panel workspace — inspector | viewer +
//    toolbar + timeline | media panel — with layout presets and a saved custom layout.
//  • iPhone: viewer, toolbar, timeline and a bottom action bar; the media library
//    and inspector open as half-height sheets that keep the timeline usable.
//  Hardware keyboard shortcuts and Apple Pencil double-tap are attached here.
//  Part 4: "on-device intelligence" menu section, save-as-template and the new
//  compact action bar entries. Part 5: AI assistant and Content Studio.
//  Part 6: AI tools menu entries, heat banner, proxy-aware preview refresh.
//

import SwiftUI
import UIKit

struct StudioView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID

    @State private var viewModel: StudioViewModel?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()
                if let viewModel {
                    StudioWorkspace(vm: viewModel, onClose: close)
                } else if failed {
                    EmptyStateView(systemImage: "exclamationmark.triangle", title: "تعذّر فتح المشروع",
                                   message: "ملف المشروع غير موجود أو تالف. يمكنك استعادة إصدار سابق من سجل الإصدارات.",
                                   actionTitle: "إغلاق") { close() }
                } else {
                    ProgressView().tint(Theme.Palette.accent)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .keyboardDoneToolbar()
        }
        .task {
            guard viewModel == nil else { return }
            if let created = StudioViewModel(projectID: projectID, env: env) {
                viewModel = created
            } else {
                failed = true
            }
        }
        .toastOverlay(env.toasts)
        .preferredColorScheme(.dark)
    }

    private func close() {
        viewModel?.close()
        env.router.closeStudio()
        dismiss()
    }
}

// MARK: - Workspace

struct StudioWorkspace: View {
    @Bindable var vm: StudioViewModel
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSize
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var keyboardFocus: Bool

    @State private var showGoTo = false
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmCloseCompound = false
    @State private var dividerStart: Double?

    private var isRegular: Bool { horizontalSize == .regular && verticalSize == .regular }
    private var isLandscapePhone: Bool { verticalSize == .compact }

    var body: some View {
        VStack(spacing: 0) {
            StudioTopBar(vm: vm, onClose: requestClose, onRename: {
                nameDraft = vm.project.name
                renaming = true
            })
            StudioBanners(vm: vm)
            Group {
                if isRegular {
                    regularLayout
                } else if isLandscapePhone {
                    landscapeLayout
                } else {
                    compactLayout
                }
            }
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .overlay {
            if let busy = vm.busy {
                BusyOverlay(operation: busy, onCancel: vm.cancelBusy)
                    .transition(.opacity)
            }
        }
        .background(PencilDoubleTapView { vm.handlePencilDoubleTap() })
        .studioKeyCommands(vm: vm, focus: $keyboardFocus, onGoTo: { showGoTo = true })
        .sheet(item: $vm.activeSheet) { sheet in
            StudioSheetHost(vm: vm, sheet: sheet)
        }
        .sheet(isPresented: $showGoTo) {
            GoToTimecodeSheet(fps: vm.frameRate, current: vm.currentTime, duration: vm.duration) { vm.seek(to: $0) }
        }
        .alert("اسم المشروع", isPresented: $renaming) {
            TextField("الاسم", text: $nameDraft)
            Button("حفظ") { vm.renameProject(nameDraft) }
            Button("إلغاء", role: .cancel) {}
        }
        .confirmationDialog("حذف المسار ومحتواه؟", isPresented: Binding(
            get: { vm.pendingDeleteTrack != nil },
            set: { if !$0 { vm.pendingDeleteTrack = nil } }
        ), titleVisibility: .visible) {
            Button("حذف المسار", role: .destructive) {
                if let index = vm.pendingDeleteTrack { vm.removeTrack(index) }
            }
        } message: {
            Text("يمكنك التراجع عن الحذف لاحقًا.")
        }
        .confirmationDialog("أنت داخل تسلسل متداخل", isPresented: $confirmCloseCompound, titleVisibility: .visible) {
            Button("تحديث التسلسل ثم الإغلاق") { vm.closeCompound { onClose() } }
            Button("إغلاق بدون تحديث", role: .destructive) { onClose() }
        } message: {
            Text("تعديلاتك محفوظة. التحديث يعيد إنشاء التسلسل حتى تظهر التغييرات في التسلسل الرئيسي.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                vm.player.pause()
                vm.persistSessionState()
                vm.env.projects.flushAutosave(vm.project)
            }
        }
        // Part 6: a ready proxy or a heat / Low Power change rebuilds the preview.
        .onChange(of: vm.env.proxies.version) { _, _ in vm.rebuildPreview(delay: 0.2) }
        .onChange(of: vm.env.performance.previewCap) { _, _ in vm.schedulePreview() }
        .animation(.easeInOut(duration: 0.2), value: vm.busy?.id)
    }

    private func requestClose() {
        if let compound = vm.editingCompound, compound.needsRender {
            confirmCloseCompound = true
        } else {
            onClose()
        }
    }

    // MARK: Layouts

    private var regularLayout: some View {
        GeometryReader { geo in
            let layout = vm.prefs.layout.clamped()
            HStack(spacing: 0) {
                if layout.showsInspector {
                    InspectorView(vm: vm)
                        .frame(width: layout.inspectorWidth)
                        .environment(\.layoutDirection, .rightToLeft)
                    PanelDivider(vertical: true) { translation, ended in
                        resize(\.inspectorWidth, by: Double(translation), ended: ended)
                    }
                }
                VStack(spacing: 0) {
                    StudioViewer(vm: vm, compact: false, onGoTo: { showGoTo = true })
                        .frame(height: max(160, geo.size.height * layout.viewerFraction))
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                    PanelDivider(vertical: false) { translation, ended in
                        resizeViewer(by: Double(translation) / max(1, Double(geo.size.height)), ended: ended)
                    }
                    StudioToolbar(vm: vm, compact: false)
                        .environment(\.layoutDirection, .rightToLeft)
                    StudioTimelineView(vm: vm, compact: false)
                }
                if layout.showsMediaPanel {
                    PanelDivider(vertical: true) { translation, ended in
                        resize(\.mediaPanelWidth, by: -Double(translation), ended: ended)
                    }
                    StudioMediaPanel(vm: vm)
                        .frame(width: layout.mediaPanelWidth)
                        .environment(\.layoutDirection, .rightToLeft)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    private var compactLayout: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                StudioViewer(vm: vm, compact: true, onGoTo: { showGoTo = true })
                    .frame(height: min(geo.size.height * 0.42, geo.size.width * 1.05))
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                StudioToolbar(vm: vm, compact: true)
                StudioTimelineView(vm: vm, compact: true)
                CompactActionBar(vm: vm)
            }
        }
    }

    private var landscapeLayout: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    StudioViewer(vm: vm, compact: true, onGoTo: { showGoTo = true })
                        .frame(width: geo.size.width * 0.46)
                        .padding(6)
                    VStack(spacing: 0) {
                        StudioToolbar(vm: vm, compact: true)
                            .environment(\.layoutDirection, .rightToLeft)
                        StudioTimelineView(vm: vm, compact: true)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
                CompactActionBar(vm: vm)
            }
        }
    }

    private func resize(_ keyPath: WritableKeyPath<StudioLayout, Double>, by delta: Double, ended: Bool) {
        if dividerStart == nil { dividerStart = vm.prefs.layout[keyPath: keyPath] }
        var layout = vm.prefs.layout
        layout[keyPath: keyPath] = (dividerStart ?? 0) + delta
        vm.prefs.layout = layout.clamped()
        if ended { dividerStart = nil }
    }

    private func resizeViewer(by fraction: Double, ended: Bool) {
        if dividerStart == nil { dividerStart = vm.prefs.layout.viewerFraction }
        var layout = vm.prefs.layout
        layout.viewerFraction = (dividerStart ?? 0.5) + fraction
        vm.prefs.layout = layout.clamped()
        if ended { dividerStart = nil }
    }
}

// MARK: - Top bar

struct StudioTopBar: View {
    @Bindable var vm: StudioViewModel
    let onClose: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.Palette.surfaceHighlight))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إغلاق المحرر")

            VStack(alignment: .leading, spacing: 1) {
                Button(action: onRename) {
                    HStack(spacing: 4) {
                        Text(vm.project.name).font(.headline).lineLimit(1)
                        Image(systemName: "pencil").font(.caption2).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                if let compound = vm.editingCompound {
                    Button { vm.closeCompound() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.forward").font(.caption2)
                            Text("التسلسل الرئيسي ‹ " + compound.name).font(.caption).lineLimit(1)
                        }
                        .foregroundStyle(Theme.Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("رجوع للتسلسل الرئيسي")
                } else {
                    Text(Fmt.resolution(vm.settings.canvasWidth, vm.settings.canvasHeight) + " • " + Fmt.fps(vm.frameRate)
                         + " • " + Fmt.duration(vm.duration))
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 6)

            if vm.isBuildingPreview {
                ProgressView().controlSize(.small).tint(Theme.Palette.accent)
            }

            Button { vm.performUndo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!vm.undo.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityLabel("تراجع")
            Button { vm.performRedo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!vm.undo.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityLabel("إعادة")

            Menu {
                Section("المشروع") {
                    Button { vm.activeSheet = .projectSettings } label: { Label("إعدادات المشروع", systemImage: "rectangle.dashed") }
                    Button { vm.activeSheet = .markers } label: { Label("العلامات", systemImage: "bookmark") }
                    Button { vm.activeSheet = .compounds } label: { Label("التسلسلات المتداخلة", systemImage: "square.stack.3d.up") }
                    Button { vm.activeSheet = .summary } label: { Label("ملخص المشروع", systemImage: "list.bullet.rectangle") }
                    Button { vm.activeSheet = .watermark } label: { Label("العلامة المائية", systemImage: "c.circle") }
                    Button { vm.saveSnapshot() } label: { Label("لقطة من الإطار الحالي", systemImage: "camera") }
                    Button { vm.activeSheet = .saveTemplate } label: { Label("حفظ كقالب", systemImage: "square.grid.3x3.square") }
                        .disabled(vm.editingCompoundID != nil)
                }
                Section("الذكاء الاصطناعي") {
                    Button { vm.activeSheet = .assistant } label: { Label("مساعد المونتاج", systemImage: "sparkles") }
                    Button { vm.activeSheet = .contentStudio } label: { Label("استوديو المحتوى", systemImage: "text.bubble") }
                        .disabled(vm.timeline.isEmpty)
                    Button { vm.activeSheet = .hookCheck } label: { Label("فحص الخطّاف قبل النشر", systemImage: "bolt.badge.clock") }
                        .disabled(vm.timeline.isEmpty)
                    Button { vm.activeSheet = .shorten } label: { Label("اختصار ذكي", systemImage: "scissors") }
                        .disabled(vm.timeline.isEmpty)
                    Button { vm.activeSheet = .translateCaptions } label: { Label("ترجمة الترجمة النصية", systemImage: "character.book.closed") }
                    Button { vm.activeSheet = .voiceoverGenerator } label: { Label("تعليق صوتي من نص", systemImage: "waveform.badge.mic") }
                    Button { vm.activeSheet = .musicSuggestions } label: { Label("اقتراح موسيقى", systemImage: "music.note.list") }
                    Button { vm.activeSheet = .thumbnail } label: { Label("صورة مصغرة تلقائية", systemImage: "photo.on.rectangle.angled") }
                        .disabled(vm.timeline.isEmpty)
                }
                Section("الذكاء على الجهاز") {
                    Button {
                        if let id = vm.primaryVideoClipID { vm.activeSheet = .smartTools(id) }
                    } label: { Label("تتبع وإعادة تأطير وتثبيت", systemImage: "wand.and.stars") }
                        .disabled(vm.primaryVideoClipID == nil)
                    Button { vm.activeSheet = .music } label: { Label("الموسيقى والإيقاع", systemImage: "metronome") }
                    Button { vm.activeSheet = .editingDNA } label: { Label("أسلوب المونتاج", systemImage: "dna") }
                    Button {
                        if let id = vm.primarySoundClipID { vm.activeSheet = .separation(id) }
                    } label: { Label("فصل الكلام عن الخلفية", systemImage: "person.wave.2") }
                        .disabled(vm.primarySoundClipID == nil)
                    Button { vm.activeSheet = .quality } label: { Label("فحص الجودة", systemImage: "checkmark.seal") }
                    Button { vm.activeSheet = .outputs } label: { Label("نسخ بمقاسات أخرى", systemImage: "rectangle.3.group") }
                        .disabled(vm.editingCompoundID != nil)
                }
                Section("النص والصوت") {
                    Button { vm.activeSheet = .captions } label: { Label("الترجمة التلقائية", systemImage: "captions.bubble") }
                    Button { vm.activeSheet = .transcript } label: { Label("التعديل بالنص", systemImage: "text.quote") }
                    Button { vm.activeSheet = .mixer } label: { Label("المكسر", systemImage: "slider.horizontal.3") }
                    Button { vm.activeSheet = .ducking } label: { Label("خفض الموسيقى تحت الكلام", systemImage: "arrow.down.right.and.arrow.up.left") }
                }
                Section("مساحة العمل") {
                    ForEach(StudioLayoutPreset.allCases) { preset in
                        Button { vm.prefs.apply(preset) } label: { Label(preset.title, systemImage: preset.symbol) }
                            .disabled(preset == .custom && vm.prefs.customLayout == nil)
                    }
                    Button { vm.prefs.saveCurrentAsCustom(); vm.env.toasts.show("تم حفظ التخطيط", style: .success) } label: {
                        Label("حفظ التخطيط الحالي", systemImage: "square.and.arrow.down")
                    }
                }
                Section {
                    Button { vm.activeSheet = .preferences } label: { Label("تفضيلات الاستوديو", systemImage: "gearshape") }
                    Button { vm.activeSheet = .shortcuts } label: { Label("اختصارات لوحة المفاتيح", systemImage: "keyboard") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("المزيد")

            Button { vm.activeSheet = .export } label: {
                Label("تصدير", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(Color(hex: 0x1A1408))
                    .background(Capsule().fill(Theme.accentGradient))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("e", modifiers: .command)
            .disabled(vm.editingCompoundID != nil)
        }
        .font(.title3)
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Palette.surface.opacity(0.95))
    }
}

/// Missing media, preview errors and warnings.
struct StudioBanners: View {
    let vm: StudioViewModel

    var body: some View {
        VStack(spacing: 0) {
            let missing = vm.missingAssetNames
            if !missing.isEmpty {
                banner(icon: "exclamationmark.triangle.fill", color: Theme.Palette.danger,
                       text: "ملفات مفقودة: " + missing.prefix(3).joined(separator: "، ")
                       + (missing.count > 3 ? " +" + Fmt.int(missing.count - 3) : "")
                       + " — اربطها من مكتبة الوسائط (الرئيسية ← الوسائط).")
            }
            if let error = vm.previewError {
                banner(icon: "xmark.octagon.fill", color: Theme.Palette.warning, text: "تعذّرت المعاينة: " + error)
            }
            if let message = vm.env.projects.lastSaveError {
                banner(icon: "externaldrive.badge.exclamationmark", color: Theme.Palette.danger, text: message)
            }
            if let cap = vm.env.performance.previewCap {
                banner(icon: "thermometer.sun.fill", color: Theme.Palette.warning,
                       text: (vm.env.performance.isLowPower && vm.env.performance.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
                              ? "وضع توفير الطاقة" : "الجهاز حار") + " — المعاينة مؤقتًا " + Fmt.int(Int(cap)) + "p. التصدير بجودته الكاملة.")
            }
        }
    }

    private func banner(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.14))
    }
}

// MARK: - Busy overlay

struct BusyOverlay: View {
    let operation: BusyOperation
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Theme.Palette.accent)
                Text(operation.title).font(.headline).foregroundStyle(Theme.Palette.textPrimary)
                Text(operation.detail).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                ProgressBarView(progress: operation.progress)
                    .frame(width: 240)
                Text(Fmt.percent(operation.progress)).font(Theme.Typo.monoLarge).foregroundStyle(Theme.Palette.textPrimary)
                if operation.cancellable {
                    Button("إلغاء", role: .cancel, action: onCancel)
                        .buttonStyle(.csSecondary)
                        .frame(width: 160)
                }
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.Palette.stroke))
            .padding(30)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Panel divider

struct PanelDivider: View {
    /// true = vertical line between side-by-side panels.
    let vertical: Bool
    let onDrag: (CGFloat, Bool) -> Void

    @State private var active = false

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.Palette.stroke)
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            Capsule()
                .fill(active ? Theme.Palette.accent : Theme.Palette.textTertiary.opacity(0.6))
                .frame(width: vertical ? 4 : 36, height: vertical ? 36 : 4)
        }
        .frame(width: vertical ? 12 : nil, height: vertical ? nil : 12)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    active = true
                    onDrag(vertical ? value.translation.width : value.translation.height, false)
                }
                .onEnded { value in
                    active = false
                    onDrag(vertical ? value.translation.width : value.translation.height, true)
                }
        )
        .accessibilityLabel("تغيير حجم اللوحات")
    }
}

// MARK: - Compact action bar (iPhone)

struct CompactActionBar: View {
    @Bindable var vm: StudioViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                action("الوسائط", "plus.rectangle.on.rectangle") { vm.activeSheet = .media }
                action("المفتش", "slider.horizontal.3", enabled: vm.primaryClip != nil) { vm.activeSheet = .inspector }
                action("الألوان", "paintpalette", enabled: canColor) {
                    if let clip = vm.primaryClip { vm.activeSheet = .colorWorkspace(clip.id) }
                }
                action("التأثيرات", "sparkles", enabled: canVisual) {
                    if let clip = vm.primaryClip { vm.activeSheet = .effects(clip.id) }
                }
                action("الانتقال", "square.split.diagonal", enabled: canVisual) {
                    if let clip = vm.primaryClip { vm.activeSheet = .transitions(clip.id) }
                }
                action("السرعة", "gauge.with.dots.needle.67percent", enabled: vm.primaryClip?.mediaAssetID != nil) {
                    vm.inspectorTab = .speed
                    vm.activeSheet = .inspector
                }
                action("تعديل", "slider.horizontal.below.square.filled.and.square") { vm.addAdjustmentLayer() }
                action("تسلسل", "square.stack.3d.up", enabled: vm.canCreateCompound) { vm.createCompound() }
                action("إطارات", "diamond", enabled: vm.primaryClip != nil) {
                    if let clip = vm.primaryClip { vm.activeSheet = .keyframes(clip.id) }
                }
                action("نص", "textformat") { vm.activeSheet = .titles }
                action("رسومات", "square.on.circle") { vm.activeSheet = .graphics }
                action("ترجمة", "captions.bubble") { vm.activeSheet = .captions }
                action("بالنص", "text.quote") { vm.activeSheet = .transcript }
                action("حركة", "wand.and.rays", enabled: !vm.selection.isEmpty) { vm.activeSheet = .motionPresets }
                action("تعليق", "mic") { vm.activeSheet = .voiceover }
                action("مؤثرات", "speaker.wave.3") { vm.activeSheet = .soundEffects }
                action("المكسر", "slider.horizontal.3") { vm.activeSheet = .mixer }
                action("الصوت", "waveform", enabled: vm.primaryClip?.mediaAssetID != nil) {
                    vm.inspectorTab = .audio
                    vm.activeSheet = .inspector
                }
                action("المساعد", "sparkles") { vm.activeSheet = .assistant }
                action("ذكي", "wand.and.stars", enabled: vm.primaryVideoClipID != nil) {
                    if let id = vm.primaryVideoClipID { vm.activeSheet = .smartTools(id) }
                }
                action("الإيقاع", "metronome") { vm.activeSheet = .music }
                action("أسلوب", "dna", enabled: !vm.timeline.isEmpty) { vm.activeSheet = .editingDNA }
                action("فصل", "person.wave.2", enabled: vm.primarySoundClipID != nil) {
                    if let id = vm.primarySoundClipID { vm.activeSheet = .separation(id) }
                }
                action("فحص", "checkmark.seal", enabled: !vm.timeline.isEmpty) { vm.activeSheet = .quality }
                action("مقاسات", "rectangle.3.group", enabled: !vm.timeline.isEmpty && vm.editingCompoundID == nil) {
                    vm.activeSheet = .outputs
                }
                action("الفراغات", "arrow.left.and.right.square", enabled: !vm.timeline.isEmpty) { vm.closeGaps(onTrack: vm.selectedTrackIndex) }
                action("لقطة", "camera", enabled: !vm.timeline.isEmpty) { vm.saveSnapshot() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
        .background(Theme.Palette.surface)
    }

    private var canVisual: Bool {
        guard let kind = vm.primaryTrackKind else { return false }
        return kind.isVisual
    }

    private var canColor: Bool {
        guard let clip = vm.primaryClip, let kind = vm.primaryTrackKind, kind.isVisual else { return false }
        switch clip.source {
        case .text, .shape, .sticker: return false
        default: return true
        }
    }

    private func action(_ title: String, _ symbol: String, enabled: Bool = true, _ perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            perform()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                Text(title).font(.caption2)
            }
            .frame(width: 64, height: 50)
            .foregroundStyle(enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
