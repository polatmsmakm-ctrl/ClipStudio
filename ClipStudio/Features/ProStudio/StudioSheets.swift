//
//  StudioSheets.swift
//  ClipStudio — Features/ProStudio
//
//  Sheets presented by the editor: inspector/media (iPhone), color workspace,
//  effects, transitions, keyframes, export (whole / in-out / selection), project
//  settings, markers, paste attributes, replace media, nested sequences and the
//  Studio preferences (also reachable from Settings). Part 3 routes titles,
//  graphics, captions, transcript editing, mixer, voiceover, sound effects,
//  ducking, project summary, motion presets and watermark. Part 4 routes smart
//  tools (reframe / tracking / stabilization), music & beat sync, Editing DNA,
//  Quality Inspector, multi-format outputs, audio separation and save-as-template.
//  Part 4 suggestions: quality check before export (preference + warning).
//  Part 5: AI editing assistant and Content Studio.
//

import SwiftUI

struct StudioSheetHost: View {
    @Bindable var vm: StudioViewModel
    let sheet: StudioSheet

    var body: some View {
        switch sheet {
        case .inspector:
            InspectorView(vm: vm, onDone: { vm.activeSheet = nil })
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        case .media:
            StudioMediaPanel(vm: vm, onDone: { vm.activeSheet = nil })
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        case .colorWorkspace(let id):
            ColorWorkspaceView(vm: vm, clipID: id)
        case .effects(let id):
            NavigationStack {
                ScrollView {
                    EffectsInspector(vm: vm, clipID: id).padding(14)
                }
                .screenBackground()
                .navigationTitle("التأثيرات")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { vm.activeSheet = nil } } }
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .transitions(let id):
            NavigationStack {
                ScrollView {
                    TransitionInspector(vm: vm, clipID: id).padding(14)
                }
                .screenBackground()
                .navigationTitle("الانتقالات")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { vm.activeSheet = nil } } }
            }
            .presentationDetents([.medium, .large])
        case .keyframes(let id):
            KeyframeEditorView(vm: vm, clipID: id)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .export:
            StudioExportSheet(vm: vm)
        case .projectSettings:
            ProjectSettingsSheet(vm: vm)
        case .markers:
            MarkersSheet(vm: vm)
        case .shortcuts:
            KeyboardShortcutsSheet()
        case .preferences:
            NavigationStack {
                StudioPreferencesView(prefs: vm.prefs)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { vm.activeSheet = nil } } }
            }
        case .pasteAttributes:
            PasteAttributesSheet(vm: vm)
        case .replaceMedia(let id):
            MediaPickerSheet(title: "استبدال المقطع", kinds: [.video, .image], allowsMultiple: false, confirmTitle: "استبدال") { assets in
                if let asset = assets.first { vm.replace(id, with: asset) }
            }
        case .compounds:
            CompoundsSheet(vm: vm)
        case .titles:
            TitlesLibrarySheet(vm: vm)
        case .graphics:
            GraphicsLibrarySheet(vm: vm)
        case .captions:
            CaptionsSheet(vm: vm)
        case .transcript:
            TranscriptEditorSheet(vm: vm)
        case .mixer:
            MixerSheet(vm: vm)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .voiceover:
            VoiceoverSheet(vm: vm)
        case .soundEffects:
            SoundEffectsSheet(vm: vm)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .ducking:
            DuckingSheet(vm: vm)
        case .summary:
            ProjectSummarySheet(vm: vm)
        case .motionPresets:
            MotionPresetsSheet(vm: vm)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .watermark:
            WatermarkSheet(vm: vm)
        case .smartTools(let id):
            SmartToolsSheet(vm: vm, clipID: id)
        case .music:
            MusicSyncSheet(vm: vm)
        case .editingDNA:
            EditingDNASheet(vm: vm)
        case .quality:
            QualityInspectorSheet(vm: vm)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .outputs:
            OutputVariantsSheet(vm: vm)
        case .separation(let id):
            AudioSeparationSheet(vm: vm, clipID: id)
        case .saveTemplate:
            SaveTemplateSheet(vm: vm)
        case .assistant:
            AssistantSheet(vm: vm)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .contentStudio:
            NavigationStack {
                ContentStudioView(projectID: vm.project.id, project: vm.project, showsDone: true)
            }
        case .voiceoverGenerator:
            VoiceoverGeneratorSheet(vm: vm)
        case .translateCaptions:
            CaptionTranslateSheet(vm: vm)
        case .musicSuggestions:
            MusicSuggestSheet(vm: vm)
        case .thumbnail:
            ThumbnailSheet(vm: vm)
        case .hookCheck:
            HookCheckSheet(vm: vm)
                .presentationDetents([.medium, .large])
        case .shorten:
            ShortenSheet(vm: vm)
        }
    }
}

// MARK: - Export

struct StudioExportSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ExportSettings
    @State private var range: StudioExportRange = .whole
    @State private var qualityProblems: [QualityIssue] = []
    @State private var showQualityWarning = false

    init(vm: StudioViewModel) {
        self.vm = vm
        _settings = State(initialValue: vm.exportSettingsForProject)
    }

    /// Part 4: the Quality Inspector runs first (when enabled) and problems are shown before exporting.
    private func exportTapped() {
        if vm.env.studioPrefs.qualityCheckBeforeExport {
            let problems = vm.runQualityCheck().filter { $0.severity == .problem }
            if !problems.isEmpty {
                qualityProblems = problems
                showQualityWarning = true
                Haptics.warning()
                return
            }
        }
        if vm.export(settings: settings, range: range) { dismiss() }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("النطاق", selection: $range) {
                        ForEach(StudioExportRange.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("ماذا تريد أن تصدّر؟")
                } footer: {
                    Text(rangeFooter)
                }
                ExportSettingsForm(settings: $settings, durationSeconds: vm.exportDuration(range), canvas: vm.canvasSize)
                Section {
                    Button {
                        exportTapped()
                    } label: {
                        Label("إضافة لقائمة التصدير", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.csPrimary)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("التصدير يتم في الخلفية من مركز التصدير. الأصل لا يتغيّر ولا يُستبدل أي ملف موجود.")
                }
            }
            .screenBackground()
            .navigationTitle("تصدير المشروع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
            .keyboardDoneToolbar()
            .confirmationDialog("فحص الجودة وجد " + Fmt.int(qualityProblems.count) + " مشكلة", isPresented: $showQualityWarning,
                                titleVisibility: .visible) {
                Button("مراجعة المشاكل") { vm.activeSheet = .quality }
                Button("تصدير على أي حال") {
                    if vm.export(settings: settings, range: range) { dismiss() }
                }
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text(qualityProblems.prefix(3).map(\.title).joined(separator: "\n")
                     + (qualityProblems.count > 3 ? "\n…" : ""))
            }
        }
    }

    private var rangeFooter: String {
        switch range {
        case .whole: return "المدة: " + Fmt.duration(vm.exportDuration(.whole))
        case .inOut:
            guard let value = vm.exportRangeValue(.inOut) else { return "حدّد نقطة البداية والنهاية (I و O) في الخط الزمني." }
            return Fmt.timecode(value.start.seconds, fps: vm.frameRate) + " ← " + Fmt.timecode(value.end.seconds, fps: vm.frameRate)
        case .selection:
            guard let value = vm.exportRangeValue(.selection) else { return "حدّد مقطعًا أو أكثر." }
            return "المدة: " + Fmt.duration(value.duration.seconds)
        }
    }
}

// MARK: - Project settings

struct ProjectSettingsSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var aspect: AspectRatio
    @State private var shortSide: Int
    @State private var frameRate: Int
    @State private var background: Color
    @State private var customWidth: Double
    @State private var customHeight: Double
    @State private var useCustom: Bool

    init(vm: StudioViewModel) {
        self.vm = vm
        let settings = vm.settings
        let aspect = settings.aspect
        _aspect = State(initialValue: aspect)
        _shortSide = State(initialValue: min(settings.canvasWidth, settings.canvasHeight))
        _frameRate = State(initialValue: settings.frameRate)
        _background = State(initialValue: settings.backgroundColor.color)
        _customWidth = State(initialValue: Double(settings.canvasWidth))
        _customHeight = State(initialValue: Double(settings.canvasHeight))
        _useCustom = State(initialValue: !AspectRatio.common.contains(aspect))
    }

    private var resultSize: CGSize {
        if useCustom { return CGSize(width: ExportGeometry.even(CGFloat(customWidth)), height: ExportGeometry.even(CGFloat(customHeight))) }
        return aspect.canvasSize(shortSide: shortSide)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("نسبة العرض") {
                    Toggle("مقاس مخصص", isOn: $useCustom)
                    if useCustom {
                        DecimalField(title: "العرض", value: $customWidth, range: 64...4096, step: 2, digits: 0, unit: "px")
                        DecimalField(title: "الارتفاع", value: $customHeight, range: 64...4096, step: 2, digits: 0, unit: "px")
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(AspectRatio.common) { option in
                                    ChipButton(title: option.label, isSelected: option == aspect) { aspect = option }
                                }
                            }
                        }
                        Picker("الدقة", selection: $shortSide) {
                            Text("720p").tag(720)
                            Text("1080p").tag(1080)
                            Text("1440p").tag(1440)
                            Text("4K").tag(2160)
                        }
                    }
                    HStack {
                        Text("حجم اللوحة")
                        Spacer()
                        Text(Fmt.resolution(Int(resultSize.width), Int(resultSize.height)))
                            .font(Theme.Typo.mono)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Section("معدل الإطارات") {
                    Picker("fps", selection: $frameRate) {
                        ForEach([24, 25, 30, 50, 60], id: \.self) { Text(Fmt.int($0) + " fps").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    ColorPicker("لون الخلفية", selection: $background, supportsOpacity: false)
                } footer: {
                    Text("تغيير المقاس لا يحذف أي شيء: المقاطع تُعاد ملاءمتها حسب وضع الملاءمة لكل مقطع.")
                }
            }
            .screenBackground()
            .navigationTitle("إعدادات المشروع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("تطبيق") {
                        var settings = ProjectSettings(canvasWidth: Int(resultSize.width), canvasHeight: Int(resultSize.height),
                                                       frameRate: frameRate)
                        settings.backgroundColor = RGBAColor(background)
                        vm.applyProjectSettings(settings)
                        dismiss()
                    }
                }
            }
            .keyboardDoneToolbar()
        }
    }
}

// MARK: - Markers

struct MarkersSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: TimelineMarker?
    @State private var nameDraft = ""

    private let palette: [UInt32] = [0xE3B04B, 0xE25C55, 0x5FC48F, 0x5B8DEF, 0xB07CE8, 0xE58F4A]

    var body: some View {
        NavigationStack {
            List {
                if vm.markers.isEmpty {
                    EmptyStateView(systemImage: "bookmark", title: "لا توجد علامات",
                                   message: "اضغط M أو زر العلامة لإضافة علامة عند رأس التشغيل.")
                        .listRowBackground(Color.clear)
                }
                ForEach(vm.markers) { marker in
                    HStack(spacing: 12) {
                        Image(systemName: "diamond.fill").foregroundStyle(marker.color.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(marker.name).font(.subheadline.weight(.semibold))
                            Text(Fmt.timecode(marker.time.seconds, fps: vm.frameRate))
                                .font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(palette, id: \.self) { hex in
                                Button { vm.setMarkerColor(marker.id, RGBAColor(hex: hex)) } label: {
                                    Label("لون", systemImage: "circle.fill")
                                }
                                .tint(Color(hex: hex))
                            }
                        } label: {
                            Image(systemName: "paintpalette").foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        vm.seek(to: marker.time.seconds)
                        dismiss()
                    }
                    .swipeActions {
                        Button(role: .destructive) { vm.removeMarker(marker.id) } label: { Label("حذف", systemImage: "trash") }
                        Button { nameDraft = marker.name; editing = marker } label: { Label("تسمية", systemImage: "pencil") }
                            .tint(Theme.Palette.accentDeep)
                    }
                    .listRowBackground(Theme.Palette.surface.opacity(0.7))
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("العلامات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { vm.addMarker() } label: { Image(systemName: "plus") }
                        .disabled(vm.editingCompoundID != nil)
                }
            }
            .alert("اسم العلامة", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("الاسم", text: $nameDraft)
                Button("حفظ") {
                    if let marker = editing { vm.renameMarker(marker.id, to: nameDraft) }
                    editing = nil
                }
                Button("إلغاء", role: .cancel) { editing = nil }
            }
        }
    }
}

// MARK: - Paste attributes

struct PasteAttributesSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: ClipAttributes = .visualLook

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(0..<ClipAttributes.ordered.count, id: \.self) { index in
                        let entry = ClipAttributes.ordered[index]
                        Toggle(isOn: Binding(
                            get: { chosen.contains(entry.0) },
                            set: { isOn in
                                if isOn { chosen.insert(entry.0) } else { chosen.remove(entry.0) }
                            }
                        )) {
                            Label(entry.1, systemImage: entry.2)
                        }
                    }
                } header: {
                    Text("الخصائص المراد لصقها على " + Fmt.int(vm.selection.count) + " مقطع")
                } footer: {
                    Text("المصدر: " + (vm.clipboard.attributeSource?.name ?? "—"))
                }
                Section {
                    Button("تحديد الكل") { chosen = .all }
                    Button("إلغاء الكل") { chosen = [] }
                }
            }
            .screenBackground()
            .navigationTitle("لصق الخصائص")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("لصق") {
                        vm.pasteAttributes(chosen)
                        dismiss()
                    }
                    .disabled(chosen.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Nested sequences

struct CompoundsSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: CompoundClip?
    @State private var nameDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if vm.project.compounds.isEmpty {
                        Text("حدّد مقاطع ثم اضغط «تسلسل» (⌘G) لتجميعها في تسلسل متداخل يمكن فتحه وتعديله لاحقًا.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    ForEach(vm.project.compounds) { compound in
                        let instances = instanceIDs(for: compound)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Theme.Palette.accent)
                                Text(compound.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                if compound.needsRender {
                                    StatusPill(text: "يحتاج تحديث", color: Theme.Palette.warning)
                                }
                            }
                            Text("\(Fmt.duration(compound.timeline.duration.seconds)) • \(Fmt.int(compound.timeline.clipCount)) مقطع • \(Fmt.int(instances.count)) نسخة في التسلسل")
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            HStack(spacing: 10) {
                                if let first = instances.first {
                                    Button("فتح") {
                                        dismiss()
                                        vm.openCompound(for: first)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                Button("تسمية") {
                                    nameDraft = compound.name
                                    renaming = compound
                                }
                                .buttonStyle(.bordered)
                                if instances.isEmpty {
                                    Button("حذف", role: .destructive) { vm.removeCompound(compound.id) }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Theme.Palette.surface.opacity(0.7))
                    }
                } footer: {
                    Text("كل تسلسل متداخل يُحفظ مع المشروع ويُعاد إنشاؤه بجودة عالية عند الخروج منه بعد التعديل.")
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("التسلسلات المتداخلة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
            .alert("اسم التسلسل", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("الاسم", text: $nameDraft)
                Button("حفظ") {
                    if let compound = renaming { vm.renameCompound(compound.id, to: nameDraft) }
                    renaming = nil
                }
                Button("إلغاء", role: .cancel) { renaming = nil }
            }
        }
    }

    private func instanceIDs(for compound: CompoundClip) -> [UUID] {
        guard let rendered = compound.renderedAssetID else { return [] }
        return vm.project.timeline.tracks.flatMap { track in
            track.clips.filter { $0.mediaAssetID == rendered }.map(\.id)
        }
    }
}

// MARK: - Preferences

struct StudioPreferencesView: View {
    @Bindable var prefs: StudioPreferences

    var body: some View {
        Form {
            Section("الخط الزمني") {
                Toggle(isOn: $prefs.snappingEnabled) { Label("الالتقاط المغناطيسي", systemImage: "magnet") }
                Toggle(isOn: $prefs.magneticTimeline) { Label("مسار رئيسي مغناطيسي (بلا فراغات)", systemImage: "rectangle.split.3x1") }
                Toggle(isOn: $prefs.rippleDeleteByDefault) { Label("الحذف المتموّج افتراضيًا", systemImage: "delete.backward") }
                Picker(selection: $prefs.trackHeight) {
                    ForEach(TrackHeightOption.allCases) { Text($0.title).tag($0) }
                } label: { Label("ارتفاع المسارات", systemImage: "rectangle.expand.vertical") }
                Toggle(isOn: $prefs.showFilmstrips) { Label("صور مصغّرة للمقاطع", systemImage: "film") }
                Toggle(isOn: $prefs.showWaveforms) { Label("موجات الصوت", systemImage: "waveform") }
                Picker(selection: $prefs.placementMode) {
                    ForEach(PlacementMode.allCases) { Text($0.title).tag($0) }
                } label: { Label("إضافة الوسائط", systemImage: "plus.rectangle.on.rectangle") }
            }
            Section("المدد الافتراضية") {
                DecimalField(title: "الانتقال", value: $prefs.defaultTransitionDuration, range: 0.1...5, step: 0.1, digits: 1, unit: "ث")
                DecimalField(title: "الصور", value: $prefs.defaultImageDuration, range: 0.5...60, step: 0.5, digits: 1, unit: "ث")
                DecimalField(title: "الإطار الثابت", value: $prefs.defaultFreezeDuration, range: 0.2...30, step: 0.5, digits: 1, unit: "ث")
                DecimalField(title: "الطبقات المولّدة", value: $prefs.defaultGeneratedDuration, range: 0.5...120, step: 0.5, digits: 1, unit: "ث")
            }
            Section("المعاينة") {
                Toggle(isOn: $prefs.showSafeGuides) { Label("حدود المنطقة الآمنة", systemImage: "rectangle.dashed") }
                Toggle(isOn: $prefs.showGrid) { Label("شبكة الأثلاث", systemImage: "grid") }
            }
            Section {
                Toggle(isOn: $prefs.qualityCheckBeforeExport) { Label("فحص الجودة قبل كل تصدير", systemImage: "checkmark.seal") }
            } header: {
                Text("التصدير")
            } footer: {
                Text("إذا وُجدت مشاكل (ملف مفقود، فراغ أسود، إطار وامض…) يظهر تنبيه مع خيار المراجعة أو التصدير على أي حال.")
            }
            Section {
                Toggle(isOn: $prefs.pencilHoverScrub) { Label("تمرير المعاينة بتحويم القلم/المؤشر", systemImage: "applepencil.and.scribble") }
                Picker(selection: $prefs.pencilDoubleTap) {
                    ForEach(PencilDoubleTapAction.allCases) { Text($0.title).tag($0) }
                } label: { Label("الضغطة المزدوجة على القلم", systemImage: "applepencil") }
            } header: {
                Text("Apple Pencil")
            } footer: {
                Text("التحويم متاح في أجهزة آيباد التي تدعم تحويم القلم أو مع لوحة اللمس.")
            }
            Section {
                Button("استعادة الإعدادات الافتراضية", role: .destructive) { prefs.resetAll() }
            }
        }
        .screenBackground()
        .navigationTitle("تفضيلات الاستوديو")
        .keyboardDoneToolbar()
    }
}
