//
//  StudioMediaPanel.swift
//  ClipStudio — Features/ProStudio
//
//  Media panel inside the editor: library with filters and search, import from
//  Photos/Files, placement mode (append / insert / overwrite at the playhead),
//  drag & drop onto any track, multi-select add, replace the selected clip, and
//  generators (adjustment layer, solid color). A side panel on iPad, a sheet on iPhone.
//

import SwiftUI

struct StudioMediaPanel: View {
    @Bindable var vm: StudioViewModel
    var onDone: (() -> Void)? = nil

    @State private var filter: MediaFilter = .all
    @State private var search = ""
    @State private var picked: [UUID] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var solidColor = Color(hex: 0x15161B)

    private var assets: [MediaAsset] {
        let library = vm.env.library
        return library.assets
            .filter { filter.matches($0, missing: library.isMissing($0)) && !library.isMissing($0) }
            .filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("الوسائط").font(.headline)
                Spacer()
                ImportMenu(showPhotos: $showPhotos, showFiles: $showFiles)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                if let onDone {
                    Button("تم", action: onDone).fontWeight(.semibold)
                }
            }
            Picker("طريقة الإضافة", selection: Binding(get: { vm.prefs.placementMode }, set: { vm.prefs.placementMode = $0 })) {
                ForEach(PlacementMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([MediaFilter.all, .video, .image, .audio]) { option in
                        ChipButton(title: option.title, isSelected: filter == option) { filter = option }
                    }
                }
            }
            TextField("بحث", text: $search)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)

            ImportProgressCard(importer: vm.env.importer)

            ScrollView {
                if assets.isEmpty {
                    EmptyStateView(systemImage: "photo.on.rectangle.angled", title: "لا توجد وسائط",
                                   message: "استورد فيديو أو صور أو صوت من الصور أو الملفات.",
                                   actionTitle: "استيراد من الصور") { showPhotos = true }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(assets) { asset in
                            let index = picked.firstIndex(of: asset.id)
                            MediaCell(asset: asset, isSelected: index != nil, selectionIndex: index.map { $0 + 1 })
                                .onTapGesture { tap(asset) }
                                .draggable(asset.id.uuidString) {
                                    Label(asset.displayName, systemImage: asset.kind.symbol)
                                        .padding(8)
                                        .background(Capsule().fill(Theme.Palette.surfaceHighlight))
                                }
                                .contextMenu { menu(for: asset) }
                        }
                    }
                }
                generators
                    .padding(.top, 12)
            }

            if !picked.isEmpty {
                HStack(spacing: 10) {
                    Button("إلغاء") { picked = [] }
                        .buttonStyle(.csSecondary)
                    Button("إضافة " + Fmt.int(picked.count)) { addPicked() }
                        .buttonStyle(.csPrimary)
                }
            }
        }
        .padding(12)
        .background(Theme.Palette.surface)
        .mediaImport(showPhotos: $showPhotos, showFiles: $showFiles) { imported in
            if !imported.isEmpty {
                vm.add(imported)
                onDone?()
            }
        }
        .keyboardDoneToolbar()
    }

    private func tap(_ asset: MediaAsset) {
        if vm.isMultiSelect || !picked.isEmpty {
            if let index = picked.firstIndex(of: asset.id) { picked.remove(at: index) } else { picked.append(asset.id) }
            Haptics.selection()
        } else {
            vm.add([asset])
            onDone?()
        }
    }

    private func addPicked() {
        let selected = picked.compactMap { vm.env.library.asset($0) }
        picked = []
        vm.add(selected)
        onDone?()
    }

    @ViewBuilder
    private func menu(for asset: MediaAsset) -> some View {
        ForEach(PlacementMode.allCases) { mode in
            Button { vm.add([asset], mode: mode); onDone?() } label: { Label(mode.title, systemImage: mode.symbol) }
        }
        Button {
            if !picked.contains(asset.id) { picked.append(asset.id) }
        } label: { Label("تحديد للإضافة المتعددة", systemImage: "checkmark.circle") }
        if let clip = vm.primaryClip, vm.selection.count == 1 {
            Button { vm.replace(clip.id, with: asset); onDone?() } label: {
                Label("استبدال المقطع المحدد", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var generators: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "مولّدات", systemImage: "wand.and.stars")
            Button {
                vm.addAdjustmentLayer()
                onDone?()
            } label: {
                Label("طبقة تعديل (تطبّق الألوان والتأثيرات على ما تحتها)", systemImage: "slider.horizontal.below.square.filled.and.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.csSecondary)
            HStack(spacing: 10) {
                ColorPicker("", selection: $solidColor, supportsOpacity: false)
                    .labelsHidden()
                Button {
                    vm.addSolidColor(RGBAColor(solidColor))
                    onDone?()
                } label: {
                    Label("لون ثابت", systemImage: "square.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.csSecondary)
            }
            Text("النصوص والعناوين والملصقات في الجزء 3.")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}
